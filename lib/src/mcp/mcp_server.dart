import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:vm_service/vm_service.dart'
    show ErrorRef, InstanceRef, RPCError, RPCErrorKind, SentinelException;

import '../console/dowel_command.dart';
import '../console/dowel_context.dart';
import '../console/dowel_input.dart';
import '../console/dowel_output.dart';
import '../console/dowel_registry.dart';
import '../console/dowel_version.dart';
import '../console/command_boot.dart';
import '../state/state_file.dart';
import '../vm/vm_service_client.dart';
import 'mcp_filter_config.dart';
import 'mcp_tool_descriptor.dart';

/// Signature for the VM Service client factory.
///
/// Production code passes [VmServiceClient.new]; tests inject a stub that
/// records `callServiceExtension` invocations without spawning Flutter.
typedef VmServiceClientFactory = VmServiceClient Function(String wsUri);

/// Signature for the state-file reader.
///
/// Production code passes [StateFile.read]; tests inject a closure returning
/// a canned map so initialize is hermetic.
typedef StateReader = Future<Map<String, dynamic>?> Function();

/// MCP server that exposes [DowelRegistry.mcpTools] to a connected MCP
/// client (Claude Code, Cursor, etc.) over a [StreamChannel] of newline-
/// delimited JSON-RPC.
///
/// Architectural choices:
///
/// - Static tool set: tools are filtered and registered ONCE, in the
///   constructor, before the handshake starts. The list never changes after
///   that, so the server sends no `notifications/tools/list_changed`.
///   `capabilities.tools.listChanged` stays at the library-default `true`;
///   never mutate it to `false` here, that would fight `ToolsSupport`'s own
///   initialize.
///
/// - Filter at registration, not at dispatch: a denied tool never reaches
///   [registerTool], so dart_mcp's built-in "no tool registered with the
///   name X" error covers the denied case automatically.
///
/// - VM Service connection owned by the server, one per process: dialled in
///   [initialize] or on the first call that needs it, dropped when the app
///   closes the socket (stop, restart) and dialled again from the session
///   file on the next call.
///
/// - Stdio transport: production wiring goes through [dart_mcp]'s
///   [stdioChannel] helper, leaving stderr free for diagnostic logging.
final class McpServer extends MCPServer with ToolsSupport {
  /// Primary constructor; consumers should prefer [McpServer.stdio] for
  /// production and [McpServer.test] for unit tests.
  McpServer._({
    required StreamChannel<String> channel,
    required this.registry,
    required this.filter,
    required VmServiceClientFactory vmClientFactory,
    required StateReader stateReader,
  })  : _vmClientFactory = vmClientFactory,
        _stateReader = stateReader,
        super.fromStreamChannel(
          channel,
          implementation: Implementation(
            name: 'dowel_mcp',
            // dowelVersion is kept in sync with pubspec.yaml `version:` on
            // each release cut; test/console/dowel_version_test.dart and
            // test/mcp/mcp_server_version_test.dart fail the build when it is
            // not. The 0.0.9 cut missed it and shipped a handshake one
            // release behind.
            version: dowelVersion,
          ),
        ) {
    _registerTools();
  }

  /// Production factory: wires stdin / stdout through [stdioChannel] and
  /// uses the real [VmServiceClient] + [StateFile.read] for discovery.
  factory McpServer.stdio({
    required DowelRegistry registry,
    required McpFilterConfig filter,
  }) =>
      McpServer._(
        channel: stdioChannel(input: stdin, output: stdout),
        registry: registry,
        filter: filter,
        vmClientFactory: VmServiceClient.new,
        stateReader: StateFile.read,
      );

  /// Test factory: caller supplies the channel + every external seam.
  factory McpServer.test({
    required StreamChannel<String> channel,
    required DowelRegistry registry,
    required McpFilterConfig filter,
    required VmServiceClientFactory vmClientFactory,
    required StateReader stateReader,
  }) =>
      McpServer._(
        channel: channel,
        registry: registry,
        filter: filter,
        vmClientFactory: vmClientFactory,
        stateReader: stateReader,
      );

  /// Source of the tool catalog and provider attribution.
  final DowelRegistry registry;

  /// Effective allow/deny axes applied once at initialize time.
  final McpFilterConfig filter;

  final VmServiceClientFactory _vmClientFactory;
  final StateReader _stateReader;

  /// VM Service client owned by this server; non-null after [initialize].
  VmServiceClient? _vmClient;

  /// Main isolate id captured at initialize time; reused for every dispatch.
  String? _isolateId;

  /// Memoized in-flight lazy-reconnect future. When two concurrent tool
  /// calls arrive while [_vmClient] is null, both await the same single
  /// connect attempt instead of each spawning a fresh [VmServiceClient]
  /// (which would leak the loser of the race). Cleared in `finally` so the
  /// next call after a failed connect can retry.
  Future<void>? _reconnecting;

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    // 1. Let ToolsSupport register its request handlers and seed the result.
    //    DO NOT mutate `result.capabilities.tools.listChanged`; the mixin
    //    has already set it to true and our V1 contract honors that.
    final result = await super.initialize(request);

    // 2. Discover the running Flutter app via the state file written by
    //    `dowel start`. State file absence is NOT fatal: the MCP server
    //    stays online, every tool is registered, and individual tool calls
    //    soft-fail at dispatch time with an actionable "run dowel start"
    //    message. This lets MCP clients (Claude Code, Cursor, Windsurf) stay
    //    connected across the natural dev cycle of starting / stopping the
    //    Flutter app without having to reconnect the server every time.
    final state = await _stateReader();
    final wsUri = state?['vmServiceUri'] as String?;
    if (wsUri != null && wsUri.isNotEmpty) {
      try {
        await _connect(wsUri);
      } catch (e) {
        stderr.writeln(
          '[dowel_mcp] VM Service connect failed: $e. '
          'Tool calls requiring VM connection will return an error; '
          'restart the Flutter app and the next call will reconnect.',
        );
      }
    } else {
      stderr.writeln(
        '[dowel_mcp] no running Flutter app detected '
        '(~/.dowel/state.json missing or empty). Tools register but VM '
        'Service calls will fail until you run `dowel start`.',
      );
    }

    return result;
  }

  // Registers the filtered tool set, from the constructor. dart_mcp
  // announces every registration made once the client's `initialized`
  // notification has landed, and a client that pipelines that notification
  // right behind `initialize` (a script driving stdio does) lands it while
  // [initialize] still awaits the state file: registering there sent one
  // `notifications/tools/list_changed` per tool ahead of the initialize
  // response. The set depends only on the registry and the filter, so
  // nothing here needs the handshake.
  void _registerTools() {
    // 1. Apply the filter once; survivors get registered, denied tools never
    //    reach `registerTool` so dart_mcp's native "no tool" error covers
    //    denied call attempts. The plugin-side tools (registry.mcpTools) AND
    //    the substrate-side tools (dowel command adapter below) flow
    //    through the same filter so a deny rule like `tools.deny:
    //    [dowel_start]` works the same as `tools.deny: [tapir_snap]`.
    final pluginTools = registry.mcpTools;
    final substrateTools = _dowelCommandTools();
    final allTools = <McpToolDescriptor>[...pluginTools, ...substrateTools];
    final filtered = filter.apply(allTools, (tool) {
      // Substrate tools belong to the synthetic provider 'dowel';
      // plugin tools defer to the registry's provider lookup.
      if (tool.extensionMethod.startsWith(_dowelDispatchPrefix)) {
        return 'dowel';
      }
      return registry.providerNameFor(tool.name) ?? '';
    });

    // 2. Register each surviving tool with its dispatch handler. dart_mcp
    //    auto-validates arguments against the wrapped ObjectSchema. The
    //    handler routes by `extensionMethod` prefix: substrate commands
    //    (prefix `dowel:`) run in-process via the registry; everything
    //    else dispatches through the VM Service.
    for (final descriptor in filtered) {
      registerTool(
        Tool(
          name: descriptor.name,
          description: descriptor.description,
          inputSchema: ObjectSchema.fromMap(descriptor.inputSchema),
        ),
        (request) => _dispatch(request, descriptor.extensionMethod),
      );
    }

    stderr.writeln(
      '[dowel_mcp] registered ${filtered.length} tools '
      '(${allTools.length - filtered.length} filtered; '
      '${pluginTools.length} plugin + ${substrateTools.length} substrate)',
    );
  }

  /// Dispatches a tool call to the matching VM Service extension and wraps
  /// the result as text content. Errors surface as `isError: true` rather
  /// than RPC failures so the client model can self-correct.
  Future<CallToolResult> _dispatch(
    CallToolRequest request,
    String extensionMethod,
  ) async {
    // Substrate command: extensionMethod looks like `dowel:<cmd>`. Routes
    // in-process via the registry; no VM Service required. Lets MCP clients
    // bootstrap the Flutter app (`dowel_start`) before any plugin tool
    // becomes available.
    if (extensionMethod.startsWith(_dowelDispatchPrefix)) {
      return _dispatchDowelCommand(
        request,
        extensionMethod.substring(_dowelDispatchPrefix.length),
      );
    }

    // Lazy-reconnect: when initialize ran without a Flutter app present
    // (state.json absent) the VM Service client is null. Retry connect on
    // every dispatch so users can `dowel start` AFTER the MCP server is
    // already serving and the very next tool call picks up the new app
    // without a reconnect cycle.
    //
    // The same path picks up a restarted app: the old client is dropped when
    // its socket closes, so `_vmClient` is null again here.
    try {
      await _ensureVmClient();
    } catch (e) {
      return CallToolResult(
        isError: true,
        content: [
          TextContent(
            text: '### Error\nVM Service connect failed: $e\n\n'
                'Run `dowel start` to launch the Flutter app, then '
                'retry the tool call.',
          ),
        ],
      );
    }

    final vmClient = _vmClient;
    final isolateId = _isolateId;
    if (vmClient == null || isolateId == null) {
      return CallToolResult(
        isError: true,
        content: [
          TextContent(
            text: '### Error\nNo Flutter app detected '
                '(~/.dowel/state.json missing or has no vmServiceUri).\n\n'
                'Run `dowel start` to launch the Flutter app, then retry '
                'the tool call. The MCP server will lazy-connect on the '
                'next invocation.',
          ),
        ],
      );
    }

    // Special-case: tapir_evaluate routes through vm.evaluate (issue #9
    // GAP F). The tapir-side ext.tapir.evaluate handler is a no-op sentinel
    // by design: an extension handler runs inside the isolate and cannot
    // call the VM Service `evaluate` RPC on itself, only a connected client
    // can. This is a known coupling of core to one plugin's tool name; a
    // descriptor-level routing hint would remove it and is a contract
    // change for every plugin, so it is not done here.
    if (request.name == 'tapir_evaluate') {
      return _dispatchEvaluate(request, vmClient, isolateId);
    }

    try {
      final args = request.arguments?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final result = await _withVmReconnect(
        vmClient,
        isolateId,
        (client, id) => client.callServiceExtension<Object?>(
          extensionMethod,
          isolateId: id,
          params: args,
        ),
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(result))]);
    } catch (e) {
      return CallToolResult(
        isError: true,
        content: [TextContent(text: '### Error\n$e')],
      );
    }
  }

  /// Routes `tapir_evaluate` MCP tool calls through VM Service `evaluate`
  /// (issue #9 GAP F). The tapir-side `ext.tapir.evaluate` handler returns
  /// a no-op sentinel because the actual evaluation requires the
  /// `vm.evaluate` RPC, which only dowel's connected MCP server can
  /// invoke. Surfaces the success path (InstanceRef), the runtime
  /// exception path (ErrorRef returned as value), the compile-error
  /// path (RPCError code 113), and the stale-isolate path
  /// (SentinelException thrown by the wrapper).
  Future<CallToolResult> _dispatchEvaluate(
    CallToolRequest request,
    VmServiceClient vmClient,
    String isolateId,
  ) async {
    final args =
        request.arguments?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final expression = args['expression'] as String?;
    if (expression == null || expression.isEmpty) {
      return CallToolResult(
        isError: true,
        content: [
          TextContent(
            text: '### Error\nMissing required argument: '
                '`expression` (non-empty string).',
          ),
        ],
      );
    }
    try {
      final result = await _withVmReconnect(
        vmClient,
        isolateId,
        (client, id) => client.evaluate(id, expression),
      );
      // 1. ErrorRef: runtime exception during evaluation; returned as
      //    a value, not thrown.
      if (result is ErrorRef) {
        return CallToolResult(
          isError: true,
          content: [
            TextContent(
              text: '### Error\nRuntime exception: '
                  '${result.message ?? '(no message)'}',
            ),
          ],
        );
      }
      // 2. InstanceRef: happy-path success.
      final value = (result is InstanceRef)
          ? (result.valueAsString ?? result.toString())
          : result.toString();
      return CallToolResult(
        content: [
          TextContent(
            text: jsonEncode(<String, dynamic>{
              'expression': expression,
              'result': value,
            }),
          ),
        ],
      );
    } on SentinelException catch (e) {
      // 3. Stale isolate: the cached isolate id was collected
      //    (hot-restart minted a new isolate); the wrapper throws.
      return CallToolResult(
        isError: true,
        content: [
          TextContent(
            text: '### Error\nIsolate sentinel encountered '
                '(kind: ${e.sentinel.kind}).\n\nRun `dowel restart` to '
                'mint a fresh isolate, then retry the evaluation.',
          ),
        ],
      );
    } on RPCError catch (e) {
      // 4. Compile error from the VM's expression compiler.
      if (e.code == 113) {
        final details = (e.data?['details'] as String?) ?? e.message;
        return CallToolResult(
          isError: true,
          content: [
            TextContent(
              text: '### Error\nExpression compilation error: $details',
            ),
          ],
        );
      }
      // 5. Other RPCError codes: surface as isError instead of bubbling
      //    out as a protocol-level failure (the dispatch contract promises
      //    "errors surface as `isError: true` rather than RPC failures").
      return CallToolResult(
        isError: true,
        content: [
          TextContent(
            text: '### Error\nVM Service RPC error (code ${e.code}): '
                '${e.message}',
          ),
        ],
      );
    } catch (e) {
      // 6. Unexpected exception: same contract: surface as isError
      //    rather than letting it bubble out.
      return CallToolResult(
        isError: true,
        content: [
          TextContent(
            text: '### Error\nUnexpected error during tapir_evaluate: $e',
          ),
        ],
      );
    }
  }

  @override
  Future<void> shutdown() async {
    await _vmClient?.disconnect();
    _vmClient = null;
    _isolateId = null;
    await super.shutdown();
  }

  // Dials the session's app when no client is live. Race guard: two
  // concurrent tool calls arriving while `_vmClient` is null both await the
  // same memoized in-flight future, so the factory runs exactly once per
  // reconnect attempt. Cleared in finally so the next call after a failed
  // connect retries cleanly.
  Future<void> _ensureVmClient() async {
    if (_vmClient != null) return;
    _reconnecting ??= _lazyReconnect();
    try {
      await _reconnecting;
    } finally {
      _reconnecting = null;
    }
  }

  /// Single in-flight connect attempt shared across concurrent tool calls.
  /// Reads state.json and connects to the URI it records. Throws on any
  /// failure so the calling dispatch surfaces an actionable error; the
  /// [_reconnecting] finally clears the guard so the next dispatch retries
  /// cleanly.
  Future<void> _lazyReconnect() async {
    final state = await _stateReader();
    final wsUri = state?['vmServiceUri'] as String?;
    if (wsUri == null || wsUri.isEmpty) {
      // No state file (or no URI) means no Flutter app running. Stay null;
      // dispatch falls through to the actionable error below.
      return;
    }
    await _connect(wsUri);
    stderr.writeln(
      '[dowel_mcp] lazy-connected to VM Service at $wsUri',
    );
  }

  // Connects one client to [wsUri] and makes it the live one.
  Future<void> _connect(String wsUri) async {
    final vmClient = _vmClientFactory(wsUri);
    await vmClient.connect();
    final isolateId = await vmClient.getMainIsolateId();
    _vmClient = vmClient;
    _isolateId = isolateId;
    // BUG #11 fix: when callServiceExtension's internal retry-on-sentinel
    // discovers the cached isolate id is stale (hot-restart minted a new
    // isolate), it refreshes via getMainIsolateId() and broadcasts the new
    // id on onIsolateRefreshed. Update the cached _isolateId in place so
    // subsequent dispatches use the fresh value without a getVM RPC per call.
    vmClient.onIsolateRefreshed.listen((fresh) => _isolateId = fresh);
    // The app stopped or restarted: vm_service disposed the connection and
    // fails every later call on it, so let the next call dial the new one.
    unawaited(vmClient.onDone.then((_) => _dropVmClient(vmClient)));
  }

  void _dropVmClient(VmServiceClient client) {
    // A late done signal from a client already replaced must not drop the
    // live one.
    if (!identical(_vmClient, client)) return;
    _vmClient = null;
    _isolateId = null;
  }

  // Runs [call] on [client]. When the call finds the connection disposed
  // (the app stopped or restarted after the last call, and the done signal
  // has not landed yet), drops the client, dials the URI the session file
  // records now and runs [call] once more. One retry only: a second
  // disposed connection is reported, not chased.
  Future<T> _withVmReconnect<T>(
    VmServiceClient client,
    String isolateId,
    Future<T> Function(VmServiceClient client, String isolateId) call,
  ) async {
    try {
      return await call(client, isolateId);
    } on RPCError catch (e) {
      if (!_isConnectionDisposed(e)) rethrow;
      _dropVmClient(client);
      await _ensureVmClient();
      final fresh = _vmClient;
      final freshIsolateId = _isolateId;
      if (fresh == null || freshIsolateId == null) rethrow;
      return await call(fresh, freshIsolateId);
    }
  }

  // vm_service lists -32010 for a disposed connection, but 15.4.0 throws
  // -32000 with this message from a call made after `dispose` and for a
  // call that was in flight when the socket closed (`_call` and `dispose`
  // in vm_service.dart), so both shapes count.
  static bool _isConnectionDisposed(RPCError e) =>
      e.code == RPCErrorKind.kConnectionDisposed.code ||
      (e.code == RPCErrorKind.kServerError.code &&
          e.message == 'Service connection disposed');

  /// Walks the registry's command list and emits an [McpToolDescriptor] for
  /// every command in [_safeDowelCommandNames]. The allowlist excludes
  /// interactive (`help`), codegen (`make:*`, `*:refresh`), MCP
  /// meta (`mcp:*`), installer (`plugin:*`, `install`) commands
  /// that either need a TTY or recurse into the MCP server itself.
  ///
  /// Tool names are normalized from `cmd:name` to `cmd_name` because MCP
  /// tool names must match `[a-zA-Z][a-zA-Z0-9_]*` (no colons). The
  /// substrate's CLI name is recovered from the extensionMethod prefix
  /// during dispatch.
  List<McpToolDescriptor> _dowelCommandTools() {
    final tools = <McpToolDescriptor>[];
    for (final command in registry.all()) {
      if (!_safeDowelCommandNames.contains(command.name)) continue;
      // MCP tool names are kebab-incompatible in some clients; replace both
      // `:` (namespace) and `-` (kebab) with `_` so every name matches
      // `[a-zA-Z][a-zA-Z0-9_]*` cleanly.
      final toolName =
          'dowel_${command.name.replaceAll(':', '_').replaceAll('-', '_')}';
      tools.add(
        McpToolDescriptor(
          name: toolName,
          // MCP descriptions are richer than the CLI command's one-liner
          // `description` field so the LLM picks the right tool reliably.
          // Format mirrors Claude Code's built-in tool descriptions
          // (imperative opening + brief context + `Usage:` bullets +
          // constraint-forward language; truncated by CC at 2KB chars).
          description: _mcpDescriptionFor(command),
          inputSchema: _commandInputSchema(command),
          extensionMethod: '$_dowelDispatchPrefix${command.name}',
        ),
      );
    }
    return tools;
  }

  /// Per-command MCP tool description in canonical Claude Code format.
  /// Falls back to the CLI [command.description] for any future allowlist
  /// addition that lacks an explicit case.
  String _mcpDescriptionFor(DowelCommand command) {
    switch (command.name) {
      case 'start':
        return 'Boot a Flutter app in detached mode and record its VM '
            'Service URI for downstream tools.\n'
            '\n'
            'Spawns `flutter run -d <device>` as a background process and '
            'writes the resulting VM Service URI + pid + web port to a '
            'session file under `~/.dowel/sessions/`, keyed by project. '
            'Other tools (dowel_status, dowel_logs, tapir_*, crumbs_*, '
            'dowel_tinker) read it to find the running app. Sessions are '
            'PER PROJECT, so two projects can be driven at once and neither '
            'overwrites the other.\n'
            '\n'
            'Usage:\n'
            '- Call this BEFORE invoking any plugin tool (tapir_snap, '
            'crumbs_tail, dowel_tinker) that needs VM Service access.\n'
            '- Default device is `chrome` (web, port 3100); pass `device: '
            '"macos"` for desktop, or `device: "<serial>"` for a connected '
            'mobile.\n'
            '- Returns once the VM Service URI is captured; the Flutter '
            'process keeps running in the background.\n'
            '- IF THIS CALL TIMES OUT, the app is probably still starting '
            'rather than broken: a cold iOS or Android build routinely takes '
            'longer than an MCP client allows a single tool call. The '
            'session is recorded before the wait, so call dowel_status to '
            'see it. A `booting: true` there means the app is up and the URI '
            'has not landed yet; the next connected tool call recovers it '
            'from the log. Do NOT re-run start, and do NOT hand-write the '
            'state file.\n'
            '- To stop call `dowel_stop`. To full-cycle restart call '
            '`dowel_restart`. For source-change reload call '
            '`dowel_reload` (state preserved) or `dowel_hot_restart` '
            '(state dropped).\n'
            '- Check `dowel_status` first and call `dowel_stop` before '
            'starting again: a second web start fails with "Port <n> is '
            'already in use", and a second start on another device launches '
            'a second app.';

      case 'stop':
        return 'Stop the currently-running Flutter app and clear its state '
            'file.\n'
            '\n'
            'Sends SIGTERM to the process group of the `flutter run` '
            'recorded in `~/.dowel/state.json` (frontend_server and the '
            'other children included), waits up to 5s, SIGKILLs the group '
            'if a member is left and waits up to 5s again, then waits up to '
            '5s for a web session\'s port; Chrome gets the same on a CDP '
            'session. Returns only once it is gone (about 15s at worst, 30s '
            'with Chrome), then deletes the state file. '
            'Safe to call when no app is running (returns success, no-op).\n'
            '\n'
            'Usage:\n'
            '- Call after development is done OR before `dowel_start` if '
            'the previous app process is stale. A start straight after it '
            'does not need a wait of its own.\n'
            '- No-op when `~/.dowel/state.json` is absent; never errors '
            'on missing state.\n'
            '- Fails with "still alive after SIGKILL" and keeps the state '
            'when the app cannot be stopped; call it again.';

      case 'status':
        return 'Return the JSON status of the recorded Flutter app.\n'
            '\n'
            'Reads `~/.dowel/state.json` and reports pid, vmServiceUri, '
            'device, webPort, profile, startedAt. Also probes whether the '
            'recorded pid is still alive (process may have crashed without '
            'cleaning state).\n'
            '\n'
            'Usage:\n'
            '- Use to discover the VM Service URI before manually '
            'connecting other tooling, or to confirm `dowel_start` '
            'succeeded.\n'
            '- Returns `{"running": false}` when no state file exists.';

      case 'logs':
        return 'Read the captured `flutter run` log output.\n'
            '\n'
            'Reads the stdout/stderr captured by the background Flutter '
            'process started via `dowel_start`. Returns the whole captured '
            'log OR tails the live stream with `follow: true`.\n'
            '\n'
            'Usage:\n'
            '- Pass `follow: true` to tail until interrupted; default '
            'returns the whole log captured since the app started.\n'
            '- Returns empty when no app has been started yet.';

      case 'restart':
        return 'Stop and re-start the running Flutter app preserving the '
            'same device.\n'
            '\n'
            'Convenience wrapper around `dowel_stop` + `dowel_start`. '
            'Slower than `dowel_reload` (which preserves Dart state) and '
            '`dowel_hot_restart` (which keeps the process alive but '
            'drops state). Only use when the others cannot apply the '
            'change (e.g. native plugin added, pubspec dep change).\n'
            '\n'
            'Usage:\n'
            '- Every parameter is optional; an omitted one keeps the value '
            'of the prior `dowel_start` (device, ports, CDP port, build mode, '
            'extra flutter arguments).\n'
            '- Pass a parameter only to change that one setting.';

      case 'reload':
        return 'Hot reload the running Flutter app.\n'
            '\n'
            'Sends `r` to the `flutter run` process stdin via the recorded '
            'FIFO pipe. Triggers Flutter\'s hot reload: Dart state is '
            'preserved, the widget tree rebuilds with the new source. The '
            'standard fast-iteration verb during Flutter development.\n'
            '\n'
            'Usage:\n'
            '- Call after every meaningful source edit to see the change '
            'immediately.\n'
            '- If hot reload fails (state mismatch, breaking source '
            'change), Flutter logs the error to the captured output; check '
            '`dowel_logs` and consider `dowel_hot_restart` instead.\n'
            '- Returns the response Flutter wrote back to stdin (typically '
            'blank on success).';

      case 'hot-restart':
        return 'Hot restart the running Flutter app (drops Dart state, '
            'keeps process).\n'
            '\n'
            'Sends `R` to the `flutter run` process stdin. Stronger than '
            '`dowel_reload`: drops all Dart state but keeps the same '
            'process + VM Service connection. Use when hot reload cannot '
            'apply the change (e.g. const constructors changed, top-level '
            'state corrupted).\n'
            '\n'
            'Usage:\n'
            '- Slower than `dowel_reload`; faster than `dowel_restart` '
            '(no process re-spawn).\n'
            '- Call when source changes invalidate existing app state but '
            'the process itself is fine.\n'
            '- Preserves the recorded VM Service URI; downstream tooling '
            'stays connected.';

      case 'doctor':
        return 'Run preflight environment checks for Flutter development.\n'
            '\n'
            'Verifies: `flutter` on PATH, `dart` on PATH, default ports '
            'free (e.g. 3100 for chrome web). Reports each check as `✓` / '
            '`✗` with the underlying command output. Exits non-zero when '
            'any hard check fails.\n'
            '\n'
            'Usage:\n'
            '- Run this when setup feels broken OR before starting a new '
            'development session on an unfamiliar machine.\n'
            '- Stale `.mcp.json` entries pointing at the removed '
            '`fluttersdk_mcp` package surface here as a WARN (advisory; '
            'not a hard failure).';

      case 'list':
        return 'List every registered dowel command grouped by '
            'namespace.\n'
            '\n'
            'Returns the full CLI command surface available to the '
            'consumer app: builtins (start, stop, doctor, etc.), plugin '
            'commands (tapir:*, crumbs:*, plugin:*), make:* generators, '
            'mcp:* meta. Useful for discovering what is available without '
            'inspecting source.\n'
            '\n'
            'Usage:\n'
            '- No parameters; returns plain text grouped by `:` namespace.\n'
            '- The total command count appears at the top so plugin '
            'loading can be sanity-checked at a glance.';

      case 'tinker':
        return 'Evaluate a Dart expression inside the running Flutter app '
            'via the VM Service `evaluate` RPC.\n'
            '\n'
            'Compiles `eval` in the scope of the app\'s root library and '
            'returns the result as text. Has full access to anything '
            'imported by `lib/main.dart`: top-level functions, '
            'singletons, services. The expression may be a simple lookup '
            '(`WidgetsBinding.instance.lifecycleState`), a method call '
            '(`MyService.instance.refresh()`), or any single Dart '
            'expression including `await`.\n'
            '\n'
            'Usage:\n'
            '- Use to INSPECT live app state without rebuilding the UI '
            '(current user, active controllers, cache contents).\n'
            '- Use to TRIGGER an action programmatically (call a '
            'controller method, fire a facade event, mutate a singleton) '
            'without going through the UI surface.\n'
            '- Requires a dowel-managed running app: call '
            '`dowel_start` first so `~/.dowel/state.json` records the '
            'VM Service URI.\n'
            '- Errors (compile, runtime, breakpoints) surface as the '
            'evaluate RPC\'s error response; the model receives the '
            'error text and can self-correct.';

      default:
        return command.description;
    }
  }

  /// Per-command JSON Schema for the 10 allowlisted commands. Each schema has
  /// one property per option the command's `configure(ArgParser)` declares,
  /// typed the way the dispatcher hands it to the command: an option is a
  /// string, a flag a boolean, a multi-option an array of strings. A parity
  /// test in `test/mcp/mcp_server_test.dart` fails when the two drift.
  Map<String, dynamic> _commandInputSchema(DowelCommand command) {
    switch (command.name) {
      case 'start':
        // One property per `StartCommand.configure` option.
        return <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'device': <String, dynamic>{
              'type': 'string',
              'description': 'Target Flutter device id. Common values: '
                  '`chrome` (web), `macos` (desktop), `<adb-serial>` '
                  '(Android), or any id from `flutter devices`. Omit to '
                  'use `chrome`.',
            },
            'port': <String, dynamic>{
              'type': 'string',
              'description': 'Web port for the chrome device as a numeric '
                  'string (Flutter parses `--port` as String). Default '
                  '`3100`. Ignored for non-web devices.',
            },
            'vm-service-port': <String, dynamic>{
              'type': 'string',
              'description': 'Port the VM Service binds to on the host as '
                  'a numeric string. Default `8181`. Change when 8181 is '
                  'already taken by a sibling process.',
            },
            'dds': <String, dynamic>{
              'type': 'boolean',
              'description': 'Enable the Dart Development Service (DDS) '
                  'proxy in front of the VM Service. Default `false`. Set '
                  '`true` when a tool needs DDS-only features.',
            },
            'profile-static': <String, dynamic>{
              'type': 'boolean',
              'description': 'Build a device (Android, iOS, desktop) with '
                  '`flutter run --profile`: release-like performance, no hot '
                  'reload. On `chrome` it only tags the session '
                  '(`profile: static`), because a web profile build has no VM '
                  'Service. Default `false`.',
            },
            'cdp-port': <String, dynamic>{
              'type': 'string',
              'description': 'Chrome DevTools Protocol port as a numeric '
                  'string. When set, pre-launches Chrome with '
                  '`--remote-debugging-port=N` and runs flutter with '
                  '`-d web-server`. Required for `tapir_resize` and '
                  '`tapir_device`. Omit for a plain start.',
            },
            'timeout': <String, dynamic>{
              'type': 'string',
              'description': 'Seconds to wait for the VM Service URI, as a '
                  'numeric string. Default `90`. Raise it for a cold native '
                  'build.',
            },
            'flutter-arg': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description': 'Extra arguments forwarded verbatim to '
                  '`flutter run`, one per item (e.g. '
                  '`["--dart-define=KEY=VALUE", "--flavor=dev"]`). Forwarded '
                  'last, so a repeated flag overrides the default this tool '
                  'chose. Carried across a restart.',
            },
          },
        };
      case 'restart':
        // One property per `RestartCommand.configure` option. Each omitted
        // one keeps the prior session's value.
        return <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'device': <String, dynamic>{
              'type': 'string',
              'description': 'Flutter device id. Omit to keep the prior '
                  'session\'s device.',
            },
            'port': <String, dynamic>{
              'type': 'string',
              'description': 'Web port as a numeric string. Omit to keep the '
                  'prior session\'s port.',
            },
            'vm-service-port': <String, dynamic>{
              'type': 'string',
              'description': 'Host VM Service port as a numeric string. Omit '
                  'to keep the prior session\'s port.',
            },
            'cdp-port': <String, dynamic>{
              'type': 'string',
              'description': 'Chrome DevTools Protocol port as a numeric '
                  'string. Omit to keep the prior session\'s port.',
            },
            'profile-static': <String, dynamic>{
              'type': 'boolean',
              'description': 'Profile build on a device. Omit to keep the '
                  'prior session\'s build mode; `false` forces a debug build.',
            },
            'flutter-arg': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description': 'Extra arguments forwarded verbatim to '
                  '`flutter run`, one per item. Omit to keep the prior '
                  'session\'s arguments; passing any replaces the whole '
                  'carried set.',
            },
          },
        };
      case 'logs':
        // Mirrors `LogsCommand.configure`: only the --follow flag exists.
        return <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'follow': <String, dynamic>{
              'type': 'boolean',
              'description': 'When `true`, tail the live log stream until '
                  'the client disconnects (`-f` short form on the CLI). '
                  'When `false` or omitted, return the whole captured log '
                  'and exit immediately. Default `false`.',
            },
          },
        };
      case 'stop':
      case 'status':
      case 'reload':
      case 'hot-restart':
      case 'doctor':
      case 'list':
        return <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        };
      case 'tinker':
        return <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'eval': <String, dynamic>{
              'type': 'string',
              'description': 'Dart expression to evaluate in the running '
                  'app\'s root library (e.g. '
                  '`WidgetsBinding.instance.lifecycleState`, '
                  '`MyService.instance.refresh()`, `1+1`). The expression '
                  'runs in the foreground isolate, `await` is auto-wrapped, '
                  'and the formatted result returns as text. Required.',
            },
          },
          'required': <String>['eval'],
        };
      default:
        // Defensive empty schema for a future allowlist addition that lands
        // without its own case. The schema parity test fails CI when that
        // command declares an option this empty schema leaves out.
        return <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        };
    }
  }

  /// In-process dispatch for substrate commands. Builds a [MapInput] from
  /// the MCP arguments, captures stdout/stderr via a [BufferedOutput], and
  /// returns the combined output (plus exit code) as MCP text content.
  Future<CallToolResult> _dispatchDowelCommand(
    CallToolRequest request,
    String commandName,
  ) async {
    final command = registry.find(commandName);
    if (command == null) {
      return CallToolResult(
        isError: true,
        content: [
          TextContent(text: '### Error\nUnknown dowel command: $commandName'),
        ],
      );
    }

    // A JSON array decodes as List<dynamic>, while a command reads a
    // multi-option (`flutter-arg`) as the List<String> ArgParser hands it on
    // the CLI. The schema already pinned the items to strings.
    final args = <String, dynamic>{
      for (final MapEntry(:key, :value)
          in (request.arguments ?? const <String, Object?>{}).entries)
        key: value is List ? List<String>.from(value) : value,
    };
    final output = BufferedOutput();
    final input = MapInput(args);

    // Build the context per the command's boot mode. Bare for filesystem /
    // process commands (start, stop, doctor, list, etc.); connected for
    // commands that need a VM Service client (tinker). Connected dispatch
    // shares the same lazy-reconnect path used by plugin VM-extension tools.
    DowelContext ctx;
    if (command.boot == CommandBoot.connected) {
      await _ensureVmClient();
      final vmClient = _vmClient;
      if (vmClient == null) {
        return CallToolResult(
          isError: true,
          content: [
            TextContent(
              text: '### Error\nNot connected to a running Flutter app. '
                  'Run `dart run dowel start` first so '
                  '`~/.dowel/state.json` records the VM Service URI.',
            ),
          ],
        );
      }
      ctx = DowelContext.connected(
        input,
        output,
        vmClient,
        registry: registry,
      );
    } else {
      ctx = DowelContext.bare(input, output, registry: registry);
    }

    try {
      final exitCode = await command.handle(ctx);
      final combined = StringBuffer()
        ..writeln('# `dowel $commandName` exit $exitCode')
        ..writeln()
        ..write(output.content);
      return CallToolResult(
        isError: exitCode != 0,
        content: [TextContent(text: combined.toString())],
      );
    } catch (e, s) {
      return CallToolResult(
        isError: true,
        content: [TextContent(text: '### Error\n$e\n\n$s')],
      );
    }
  }

  /// Convenience entry: build a stdio-wired server and block until the
  /// peer closes the channel. Intended for `bin/mcp.dart` (Step 22).
  static Future<void> serve({
    required DowelRegistry registry,
    required McpFilterConfig filter,
  }) async {
    final server = McpServer.stdio(registry: registry, filter: filter);
    await server.done;
  }
}

/// Prefix that marks a substrate command in an [McpToolDescriptor]
/// `extensionMethod`. The dispatcher routes any descriptor whose method
/// starts with this prefix through the in-process command runner instead of
/// the VM Service.
const String _dowelDispatchPrefix = 'dowel:';

/// Substrate commands the MCP server exposes as tools by default. The
/// allowlist intentionally excludes codegen (`make:*`, `*:refresh`),
/// installer (`plugin:*`, `install`), and MCP meta (`mcp:*`)
/// commands because they either mutate source on disk in ways better served
/// by the client's own file tools, or recurse into the MCP server itself.
///
/// `tinker` is included even though it boots as [CommandBoot.connected];
/// the dispatcher in [McpServer._dispatchDowelCommand] detects the boot
/// mode and constructs an [DowelContext.connected] using the lazily
/// established VM Service client. From the MCP client's point of view it is
/// an ordinary substrate tool that takes an `eval` argument and returns the
/// evaluated Dart expression as text.
const Set<String> _safeDowelCommandNames = <String>{
  'start',
  'stop',
  'status',
  'logs',
  'restart',
  'reload',
  'hot-restart',
  'doctor',
  'list',
  'tinker',
};

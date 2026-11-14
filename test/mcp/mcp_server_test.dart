import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:dowel/dowel.dart';
import 'package:dowel/src/commands/doctor_command.dart';
import 'package:dowel/src/commands/list_command.dart';
import 'package:dowel/src/commands/logs_command.dart';
import 'package:dowel/src/commands/reload_command.dart';
import 'package:dowel/src/commands/status_command.dart';
import 'package:dowel/src/mcp/mcp_filter_config.dart';
import 'package:dowel/src/mcp/mcp_server.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart'
    show ErrorRef, InstanceRef, RPCError, Response, SentinelException;

/// In-memory stub of [VmServiceClient] that records calls and replays canned
/// responses keyed by extension method name.
///
/// Production code never touches a real isolate during tests; we substitute
/// the whole VM Service surface via constructor injection so the McpServer
/// flow can be exercised end-to-end without spawning Flutter.
class _StubVmServiceClient extends VmServiceClient {
  _StubVmServiceClient({
    Map<String, Object?>? responses,
    this.failOnConnect = false,
  }) : responses = responses ?? <String, Object?>{},
       super('ws://stub-only/');

  static const _stubIsolateId = 'isolate-stub';

  final Map<String, Object?> responses;
  final bool failOnConnect;

  /// Every `callServiceExtension` invocation captured in arrival order.
  final List<({String method, String isolateId, Map<String, dynamic>? params})>
  calls = [];

  /// Set to true after [connect] is called at least once.
  bool didConnect = false;

  /// Connection-attempt count. The lazy-reconnect race guard test asserts
  /// this stays at 1 even under N concurrent dispatches starting from a
  /// null `_vmClient`.
  int connectCount = 0;

  @override
  Future<void> connect() async {
    connectCount++;
    if (failOnConnect) {
      throw StateError('stub connect failure');
    }
    // Yield once so concurrent waiters get a chance to interleave; without
    // this the test cannot exercise the race window.
    await Future<void>.delayed(Duration.zero);
    didConnect = true;
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<String> getMainIsolateId() async => _stubIsolateId;

  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get onDone => _done.future;

  /// What every call throws once [dispose] ran; null while the connection is
  /// live.
  RPCError? _disposedError;

  /// Disposes the connection the way vm_service does when the app goes away:
  /// every later call fails with an RPC error carrying [code], and [onDone]
  /// completes unless [notifyDone] is false (a call already in flight sees
  /// the error before the done signal lands).
  void dispose({int code = -32010, bool notifyDone = true}) {
    _disposedError = RPCError(
      'callServiceExtension',
      code,
      'Service connection disposed',
    );
    if (notifyDone) _done.complete();
  }

  @override
  Future<T> callServiceExtension<T>(
    String method, {
    required String isolateId,
    Map<String, dynamic>? params,
  }) async {
    calls.add((method: method, isolateId: isolateId, params: params));
    final disposed = _disposedError;
    if (disposed != null) throw disposed;
    if (!responses.containsKey(method)) {
      throw StateError('stub has no canned response for $method');
    }
    return responses[method] as T;
  }

  /// Every `evaluate` invocation captured in arrival order. The Step 4 RED
  /// tests assert on this tuple to confirm the new `tapir_evaluate` dispatch
  /// path routes the request's `expression` argument through to
  /// `VmServiceClient.evaluate` with the resolved isolate id.
  final List<({String isolateId, String expression})> evaluateCalls = [];

  /// Per-test script that produces the canned [Response] for the next
  /// [evaluate] call. Tests assign this to control the branch under test
  /// (InstanceRef success, ErrorRef value, SentinelException throw, or
  /// RPCError(113) throw). Default: a no-op `InstanceRef` that triggers the
  /// unconfigured-script failure mode.
  Response Function(String isolateId, String expression)? _evaluateScript;

  @override
  Future<Response> evaluate(String isolateId, String expression) async {
    evaluateCalls.add((isolateId: isolateId, expression: expression));
    final disposed = _disposedError;
    if (disposed != null) throw disposed;
    final script = _evaluateScript;
    if (script == null) {
      throw StateError('stub has no _evaluateScript configured');
    }
    return script(isolateId, expression);
  }
}

/// Provider double that returns a fixed list of MCP tool descriptors.
class _FakeMcpProvider extends DowelServiceProvider {
  _FakeMcpProvider({required this.providerName, required this.tools});

  @override
  final String providerName;
  final List<McpToolDescriptor> tools;

  @override
  List<DowelCommand> commands() => const [];

  @override
  List<McpToolDescriptor> mcpTools() => tools;
}

/// Builds the descriptor + provider pair without repeating the boilerplate
/// per test.
McpToolDescriptor _tool(
  String name, {
  String? extensionMethod,
  Map<String, dynamic>? inputSchema,
}) => McpToolDescriptor(
  name: name,
  description: 'Test tool $name.',
  inputSchema: inputSchema ?? const {'type': 'object', 'properties': {}},
  extensionMethod: extensionMethod ?? 'ext.test.$name',
);

/// Wires the server + a real dart_mcp client around an in-memory channel pair
/// so tests drive the server through its true public protocol surface.
///
/// Returns the live [ServerConnection]; teardown is the test's responsibility
/// (the harness shuts both ends down via [_TestHarness.dispose]).
class _TestHarness {
  _TestHarness._({
    required this.server,
    required this.connection,
    required this.client,
    required this.stub,
  });

  final McpServer server;
  final ServerConnection connection;
  final MCPClient client;
  final _StubVmServiceClient stub;

  static Future<_TestHarness> build({
    required DowelRegistry registry,
    required McpFilterConfig filter,
    Map<String, Object?>? stubResponses,
    bool stubFailOnConnect = false,
    Map<String, dynamic>? stateOverride,
    Future<Map<String, dynamic>?> Function()? stateReader,
    VmServiceClientFactory? vmClientFactory,
  }) async {
    // 1. Two paired channels: one for the server (super.fromStreamChannel),
    //    one for the client (connectServer).
    final controller = StreamChannelController<String>(sync: true);

    // 2. Stub the VM Service + state reader so initialize is hermetic.
    final stub = _StubVmServiceClient(
      responses: stubResponses,
      failOnConnect: stubFailOnConnect,
    );
    final defaultState = <String, dynamic>{
      'vmServiceUri': 'ws://stub-only/',
      'pid': 12345,
    };

    final server = McpServer.test(
      channel: controller.local,
      registry: registry,
      filter: filter,
      vmClientFactory: vmClientFactory ?? (_) => stub,
      stateReader: stateReader ?? () async => stateOverride ?? defaultState,
    );

    // 3. Drive the server with a real client over the foreign side.
    final client = MCPClient(
      Implementation(name: 'mcp_server_test', version: '1.0.0'),
    );
    final connection = client.connectServer(controller.foreign);
    final init = await connection.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: ClientCapabilities(),
        clientInfo: Implementation(
          name: 'mcp_server_test_client',
          version: '1.0.0',
        ),
      ),
    );
    expect(init.protocolVersion, ProtocolVersion.latestSupported);
    connection.notifyInitialized();
    // Yield so notifications/initialized reaches the server before tests
    // start asserting `tools/list`.
    await Future<void>.delayed(Duration.zero);

    return _TestHarness._(
      server: server,
      connection: connection,
      client: client,
      stub: stub,
    );
  }

  Future<void> dispose() async {
    await connection.shutdown();
    await client.shutdown();
    await server.shutdown();
  }
}

void main() {
  group('McpServer.initialize', () {
    test('empty registry produces a tools/list of zero tools', () async {
      final registry = DowelRegistry();
      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);

      final result = await harness.connection.listTools();

      expect(result.tools, isEmpty);
    });

    test('registers every surviving tool from the registry', () async {
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'tapir',
            tools: [
              _tool('tapir_snap', extensionMethod: 'ext.tapir.snap'),
              _tool('tapir_tap', extensionMethod: 'ext.tapir.tap'),
            ],
          ),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);

      final result = await harness.connection.listTools();

      expect(result.tools.map((t) => t.name), ['tapir_snap', 'tapir_tap']);
    });

    test(
      'keeps capabilities.tools.listChanged at the library default true',
      () async {
        final registry = DowelRegistry();
        final harness = await _TestHarness.build(
          registry: registry,
          filter: McpFilterConfig.empty(),
        );
        addTearDown(harness.dispose);

        // ToolsSupport.initialize sets listChanged = true unconditionally; our
        // override must not flip it back to false (Oracle C1 revise: honest
        // capability advertisement).
        expect(
          harness.connection.serverCapabilities.tools?.listChanged,
          isTrue,
        );
      },
    );

    test('connects the VM Service client during initialize', () async {
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(providerName: 'tapir', tools: [_tool('tapir_snap')]),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);

      expect(harness.stub.didConnect, isTrue);
    });

    test(
      'lazy-reconnect serializes via memoized future under concurrent dispatch',
      () async {
        // Race scenario: init runs with state.json absent (_vmClient stays
        // null + server stays online). state.json appears (user runs
        // `dowel start`). Two MCP tool calls arrive concurrently. Both see
        // _vmClient == null and trigger the lazy-reconnect branch in _dispatch.
        // The race guard MUST ensure the VmServiceClient factory runs exactly
        // once across the two concurrent dispatches (no leak).
        var stateRevealed = false;
        final registry = DowelRegistry()
          ..registerMcpToolsFor(
            _FakeMcpProvider(
              providerName: 'tapir',
              tools: [_tool('tapir_snap', extensionMethod: 'ext.tapir.snap')],
            ),
          );

        final harness = await _TestHarness.build(
          registry: registry,
          filter: McpFilterConfig.empty(),
          stubResponses: <String, Object?>{
            'ext.tapir.snap': <String, dynamic>{'ok': true},
          },
          stateReader: () async {
            // Return absent state during initialize; valid state on every
            // subsequent call (which is the lazy-reconnect path).
            if (!stateRevealed) {
              stateRevealed = true;
              return null;
            }
            return <String, dynamic>{
              'vmServiceUri': 'ws://stub-only/',
              'pid': 12345,
            };
          },
        );
        addTearDown(harness.dispose);

        // Sanity: initialize ran without connecting (state was absent).
        expect(harness.stub.connectCount, 0);

        // Fire two concurrent tool calls; both should hit the lazy-reconnect
        // branch with a null _vmClient.
        final results = await Future.wait([
          harness.connection.callTool(
            CallToolRequest(name: 'tapir_snap', arguments: const {}),
          ),
          harness.connection.callTool(
            CallToolRequest(name: 'tapir_snap', arguments: const {}),
          ),
        ]);

        // Both calls succeeded.
        expect(results.every((r) => r.isError != true), isTrue);
        // The race guard ran the factory exactly once even though both
        // dispatches needed the connection.
        expect(harness.stub.connectCount, 1);
        // Both dispatches reached the stub extension call.
        expect(harness.stub.calls, hasLength(2));
      },
    );

    test('substrate commands surface as dowel_* MCP tools', () async {
      // The 10 allowlisted substrate commands MUST appear as MCP tools even
      // when no plugin providers are registered. This is the bootstrap path:
      // an MCP client (Claude Code) can call dowel_start BEFORE any
      // Flutter app is running.
      final registry = DowelRegistry();
      registry.registerAll(<DowelCommand>[
        _FakeSubstrateCommand(
          'start',
          'Boot flutter run -d <device> detached.',
        ),
        _FakeSubstrateCommand('doctor', 'Run environment preflight checks.'),
      ], providerName: 'dowel');

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);

      final tools = await harness.connection.listTools();
      final names = tools.tools.map((t) => t.name).toList();
      expect(names, contains('dowel_start'));
      expect(names, contains('dowel_doctor'));
    });

    test(
      'dowel_* tool dispatch runs command in-process + returns output',
      () async {
        final registry = DowelRegistry();
        registry.registerAll(<DowelCommand>[
          _FakeSubstrateCommand(
            'status',
            'Print JSON status.',
            onHandle: (ctx) async {
              ctx.output.info('{"running":false}');
              return 0;
            },
          ),
        ], providerName: 'dowel');

        final harness = await _TestHarness.build(
          registry: registry,
          filter: McpFilterConfig.empty(),
        );
        addTearDown(harness.dispose);

        final result = await harness.connection.callTool(
          CallToolRequest(name: 'dowel_status', arguments: const {}),
        );
        expect(result.isError, isFalse);
        final text = (result.content.first as TextContent).text;
        expect(text, contains('# `dowel status` exit 0'));
        expect(text, contains('{"running":false}'));
      },
    );

    test('dowel_logs description states the exit 1 with no log', () async {
      final registry = DowelRegistry();
      registry.registerAll(<DowelCommand>[
        _FakeSubstrateCommand('logs', 'Print the log.'),
      ], providerName: 'dowel');

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);

      final tools = await harness.connection.listTools();
      final description = tools.tools
          .singleWhere((t) => t.name == 'dowel_logs')
          .description!;
      expect(description, isNot(contains('Returns empty')));
      expect(description, contains('exits 1'));
      expect(description, contains('dowel_start'));
      expect(description, isNot(contains('follow: true')));
    });

    test(
      'initialize stays online when state.json has no vmServiceUri',
      () async {
        // V1 soft-fail policy: the MCP server stays connected even when no
        // Flutter app is running. Individual tool calls return an actionable
        // error at dispatch time so MCP clients (Claude Code, Cursor) can
        // survive the natural dev cycle of starting/stopping the app without
        // having to reconnect the server every time.
        final registry = DowelRegistry()
          ..registerMcpToolsFor(
            _FakeMcpProvider(
              providerName: 'tapir',
              tools: [_tool('tapir_snap')],
            ),
          );

        final harness = await _TestHarness.build(
          registry: registry,
          filter: McpFilterConfig.empty(),
          stateOverride: const <String, dynamic>{},
        );
        addTearDown(harness.dispose);

        // Server initialized cleanly; tools registered.
        expect(harness.stub.didConnect, isFalse);
        final tools = await harness.connection.listTools();
        expect(tools.tools.map((t) => t.name), contains('tapir_snap'));

        // Tool call surfaces the actionable error at dispatch time.
        final result = await harness.connection.callTool(
          CallToolRequest(name: 'tapir_snap', arguments: const {}),
        );
        expect(result.isError, isTrue);
        final text = (result.content.first as TextContent).text;
        expect(text, contains('dowel start'));
        expect(text, contains('No Flutter app detected'));
      },
    );
  });

  group('McpServer filter application', () {
    test('package deny removes every tool from that provider', () async {
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'tapir',
            tools: [_tool('tapir_snap'), _tool('tapir_tap')],
          ),
        )
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'crumbs',
            tools: [_tool('crumbs_tail'), _tool('crumbs_http')],
          ),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: const McpFilterConfig(
          packagesAllow: null,
          packagesDeny: {'crumbs'},
          toolsAllow: null,
          toolsDeny: {},
        ),
      );
      addTearDown(harness.dispose);

      final result = await harness.connection.listTools();

      expect(result.tools.map((t) => t.name), ['tapir_snap', 'tapir_tap']);
    });

    test('tool deny removes the matching tool BEFORE registerTool', () async {
      // Behaviour proof: a denied tool returns a "no tool registered" error
      // from dart_mcp's CallTool dispatcher, not our dispatch try/catch.
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'tapir',
            tools: [_tool('tapir_snap'), _tool('tapir_tap')],
          ),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: const McpFilterConfig(
          packagesAllow: null,
          packagesDeny: {},
          toolsAllow: null,
          toolsDeny: {'tapir_snap'},
        ),
      );
      addTearDown(harness.dispose);

      final result = await harness.connection.listTools();
      expect(result.tools.map((t) => t.name), ['tapir_tap']);

      final callResult = await harness.connection.callTool(
        CallToolRequest(name: 'tapir_snap'),
      );
      expect(callResult.isError, isTrue);
      expect(
        (callResult.content.single as TextContent).text,
        contains('No tool registered'),
      );
      // The stub was never asked to dispatch the denied tool.
      expect(
        harness.stub.calls.where((c) => c.method == 'ext.tapir.snap'),
        isEmpty,
      );
    });
  });

  group('McpServer tools/call dispatch', () {
    test(
      'forwards to the correct extensionMethod with the request arguments',
      () async {
        final registry = DowelRegistry()
          ..registerMcpToolsFor(
            _FakeMcpProvider(
              providerName: 'tapir',
              tools: [_tool('tapir_snap', extensionMethod: 'ext.tapir.snap')],
            ),
          );

        final harness = await _TestHarness.build(
          registry: registry,
          filter: McpFilterConfig.empty(),
          stubResponses: const {
            'ext.tapir.snap': {'yaml': '- node'},
          },
        );
        addTearDown(harness.dispose);

        final callResult = await harness.connection.callTool(
          CallToolRequest(name: 'tapir_snap', arguments: const {}),
        );

        expect(harness.stub.calls.single.method, 'ext.tapir.snap');
        expect(harness.stub.calls.single.isolateId, 'isolate-stub');
        expect(callResult.isError, anyOf(isNull, isFalse));
        final text = (callResult.content.single as TextContent).text;
        expect(jsonDecode(text), {'yaml': '- node'});
      },
    );

    test('wraps dispatch exceptions in CallToolResult.isError=true', () async {
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'tapir',
            tools: [_tool('tapir_snap', extensionMethod: 'ext.tapir.snap')],
          ),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
        // No canned response -> stub throws StateError on dispatch.
      );
      addTearDown(harness.dispose);

      final callResult = await harness.connection.callTool(
        CallToolRequest(name: 'tapir_snap'),
      );

      expect(callResult.isError, isTrue);
      expect(
        (callResult.content.single as TextContent).text,
        contains('### Error'),
      );
    });

    test(
      'inputSchema validation rejects calls missing a required arg',
      () async {
        final registry = DowelRegistry()
          ..registerMcpToolsFor(
            _FakeMcpProvider(
              providerName: 'magic_tinker',
              tools: [
                _tool(
                  'tinker_eval',
                  extensionMethod: 'ext.tinker.evaluate',
                  inputSchema: const {
                    'type': 'object',
                    'properties': {
                      'ref': {'type': 'string'},
                    },
                    'required': ['ref'],
                  },
                ),
              ],
            ),
          );

        final harness = await _TestHarness.build(
          registry: registry,
          filter: McpFilterConfig.empty(),
        );
        addTearDown(harness.dispose);

        final callResult = await harness.connection.callTool(
          CallToolRequest(name: 'tinker_eval', arguments: const {}),
        );

        expect(callResult.isError, isTrue);
        // Stub was never reached because dart_mcp short-circuited on the
        // missing required arg.
        expect(harness.stub.calls, isEmpty);
      },
    );

    test('tapir_evaluate routes through vm.evaluate and returns the '
        'InstanceRef value as JSON', () async {
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'tapir',
            tools: [
              _tool('tapir_evaluate', extensionMethod: 'ext.tapir.evaluate'),
            ],
          ),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);
      harness.stub._evaluateScript = (_, _) =>
          InstanceRef(kind: 'Int', valueAsString: '3', id: 'objects/int-3');

      final callResult = await harness.connection.callTool(
        CallToolRequest(
          name: 'tapir_evaluate',
          arguments: const {'expression': '1 + 2'},
        ),
      );

      expect(harness.stub.evaluateCalls.single, (
        isolateId: 'isolate-stub',
        expression: '1 + 2',
      ));
      expect(callResult.isError, anyOf(isNull, isFalse));
      final text = (callResult.content.single as TextContent).text;
      expect(jsonDecode(text), {'expression': '1 + 2', 'result': '3'});
    });

    test('tapir_evaluate surfaces ErrorRef result as isError with a '
        'Runtime exception message', () async {
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'tapir',
            tools: [
              _tool('tapir_evaluate', extensionMethod: 'ext.tapir.evaluate'),
            ],
          ),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);
      harness.stub._evaluateScript = (_, _) => ErrorRef(
        kind: 'UnhandledException',
        message: 'NoSuchMethodError: foo',
        id: 'objects/error-1',
      );

      final callResult = await harness.connection.callTool(
        CallToolRequest(
          name: 'tapir_evaluate',
          arguments: const {'expression': '1 + 2'},
        ),
      );

      expect(harness.stub.evaluateCalls.single, (
        isolateId: 'isolate-stub',
        expression: '1 + 2',
      ));
      expect(callResult.isError, isTrue);
      final text = (callResult.content.single as TextContent).text;
      expect(text, contains('### Error'));
      expect(text, contains('Runtime exception'));
      expect(text, contains('NoSuchMethodError: foo'));
    });

    test('tapir_evaluate maps SentinelException to isError with an '
        'Isolate sentinel hint', () async {
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'tapir',
            tools: [
              _tool('tapir_evaluate', extensionMethod: 'ext.tapir.evaluate'),
            ],
          ),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);
      harness.stub._evaluateScript = (_, _) => throw SentinelException.parse(
        'evaluate',
        <String, dynamic>{'kind': 'Collected', 'type': '@Sentinel'},
      );

      final callResult = await harness.connection.callTool(
        CallToolRequest(
          name: 'tapir_evaluate',
          arguments: const {'expression': '1 + 2'},
        ),
      );

      expect(harness.stub.evaluateCalls.single, (
        isolateId: 'isolate-stub',
        expression: '1 + 2',
      ));
      expect(callResult.isError, isTrue);
      final text = (callResult.content.single as TextContent).text;
      expect(text, contains('### Error'));
      expect(text, contains('Isolate sentinel'));
      // Actionable hint pointing the user at the recovery command. The exact
      // wording locks in Step 7; assert only on the stable substring.
      expect(text, contains('dowel'));
    });

    test('tapir_evaluate translates RPCError code 113 into a compile-error '
        'message', () async {
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'tapir',
            tools: [
              _tool('tapir_evaluate', extensionMethod: 'ext.tapir.evaluate'),
            ],
          ),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);
      harness.stub._evaluateScript = (_, _) => throw RPCError(
        'evaluate',
        113,
        'Expression compilation error',
        <String, dynamic>{'details': 'Unterminated string literal'},
      );

      final callResult = await harness.connection.callTool(
        CallToolRequest(
          name: 'tapir_evaluate',
          arguments: const {'expression': '1 + 2'},
        ),
      );

      expect(harness.stub.evaluateCalls.single, (
        isolateId: 'isolate-stub',
        expression: '1 + 2',
      ));
      expect(callResult.isError, isTrue);
      final text = (callResult.content.single as TextContent).text;
      expect(text, contains('### Error'));
      expect(text, contains('Expression compilation error'));
      expect(text, contains('Unterminated string literal'));
    });

    test('tapir_evaluate translates non-113 RPCError into an isError result '
        'instead of bubbling as a protocol-level failure', () async {
      // The dispatch contract states errors surface as `isError: true`
      // rather than RPC failures. A non-113 RPCError (e.g. method-not-found,
      // permission-denied) must follow that contract, not bubble up.
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'tapir',
            tools: [
              _tool('tapir_evaluate', extensionMethod: 'ext.tapir.evaluate'),
            ],
          ),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);
      harness.stub._evaluateScript = (_, _) =>
          throw RPCError('evaluate', -32601, 'Method not found');

      final callResult = await harness.connection.callTool(
        CallToolRequest(
          name: 'tapir_evaluate',
          arguments: const {'expression': '1 + 2'},
        ),
      );

      expect(harness.stub.evaluateCalls.single, (
        isolateId: 'isolate-stub',
        expression: '1 + 2',
      ));
      expect(callResult.isError, isTrue);
      final text = (callResult.content.single as TextContent).text;
      expect(text, contains('### Error'));
      expect(text, contains('VM Service RPC error'));
      expect(text, contains('-32601'));
      expect(text, contains('Method not found'));
    });

    test('tapir_evaluate translates an unexpected exception into an isError '
        'result instead of bubbling as a protocol-level failure', () async {
      final registry = DowelRegistry()
        ..registerMcpToolsFor(
          _FakeMcpProvider(
            providerName: 'tapir',
            tools: [
              _tool('tapir_evaluate', extensionMethod: 'ext.tapir.evaluate'),
            ],
          ),
        );

      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);
      harness.stub._evaluateScript = (_, _) =>
          throw StateError('isolate root library unavailable');

      final callResult = await harness.connection.callTool(
        CallToolRequest(
          name: 'tapir_evaluate',
          arguments: const {'expression': '1 + 2'},
        ),
      );

      expect(callResult.isError, isTrue);
      final text = (callResult.content.single as TextContent).text;
      expect(text, contains('### Error'));
      expect(text, contains('Unexpected error during tapir_evaluate'));
      expect(text, contains('isolate root library unavailable'));
    });
  });

  group('McpServer VM Service reconnect', () {
    // Each connect gets a fresh client, the way a restarted app hands out a
    // new VM Service socket.
    VmServiceClientFactory restartableFactory(
      List<_StubVmServiceClient> clients, {
      void Function(_StubVmServiceClient client)? onCreate,
    }) {
      return (_) {
        final client = _StubVmServiceClient(
          responses: <String, Object?>{
            'ext.tapir.snap': <String, dynamic>{'ok': clients.length},
          },
        );
        onCreate?.call(client);
        clients.add(client);
        return client;
      };
    }

    DowelRegistry snapRegistry() => DowelRegistry()
      ..registerMcpToolsFor(
        _FakeMcpProvider(
          providerName: 'tapir',
          tools: [_tool('tapir_snap', extensionMethod: 'ext.tapir.snap')],
        ),
      );

    test(
      'drops a client whose connection closed and reconnects on next call',
      () async {
        final clients = <_StubVmServiceClient>[];
        final harness = await _TestHarness.build(
          registry: snapRegistry(),
          filter: McpFilterConfig.empty(),
          vmClientFactory: restartableFactory(clients),
        );
        addTearDown(harness.dispose);

        final before = await harness.connection.callTool(
          CallToolRequest(name: 'tapir_snap', arguments: const {}),
        );
        expect(before.isError, isNot(isTrue));

        // The app stopped: vm_service disposed the socket and fired onDone.
        clients.single.dispose();
        await Future<void>.delayed(Duration.zero);

        final after = await harness.connection.callTool(
          CallToolRequest(name: 'tapir_snap', arguments: const {}),
        );

        expect(after.isError, isNot(isTrue));
        expect(jsonDecode((after.content.single as TextContent).text), {
          'ok': 1,
        });
        expect(clients, hasLength(2));
        // The disposed client never saw the second call.
        expect(clients.first.calls, hasLength(1));
        expect(clients.last.calls, hasLength(1));
      },
    );

    for (final code in <int>[-32010, -32000]) {
      test('retries once on a fresh connection when an in-flight call finds '
          'the connection disposed (code $code)', () async {
        final clients = <_StubVmServiceClient>[];
        final harness = await _TestHarness.build(
          registry: snapRegistry(),
          filter: McpFilterConfig.empty(),
          vmClientFactory: restartableFactory(clients),
        );
        addTearDown(harness.dispose);

        // Disposed before onDone lands, so only the call's error tells.
        clients.single.dispose(code: code, notifyDone: false);

        final result = await harness.connection.callTool(
          CallToolRequest(name: 'tapir_snap', arguments: const {}),
        );

        expect(result.isError, isNot(isTrue));
        expect(clients, hasLength(2));
        expect(clients.first.calls, hasLength(1));
        expect(clients.last.calls, hasLength(1));
      });
    }

    test('reconnects only once per call', () async {
      final clients = <_StubVmServiceClient>[];
      final harness = await _TestHarness.build(
        registry: snapRegistry(),
        filter: McpFilterConfig.empty(),
        // Every client is dead on arrival: the reconnect must not loop.
        vmClientFactory: restartableFactory(
          clients,
          onCreate: (client) => client.dispose(notifyDone: false),
        ),
      );
      addTearDown(harness.dispose);

      final result = await harness.connection.callTool(
        CallToolRequest(name: 'tapir_snap', arguments: const {}),
      );

      expect(result.isError, isTrue);
      expect(
        (result.content.single as TextContent).text,
        contains('Service connection disposed'),
      );
      expect(clients, hasLength(2));
    });

    test(
      'tapir_evaluate retries on a fresh connection after disposal',
      () async {
        final clients = <_StubVmServiceClient>[];
        final registry = DowelRegistry()
          ..registerMcpToolsFor(
            _FakeMcpProvider(
              providerName: 'tapir',
              tools: [
                _tool('tapir_evaluate', extensionMethod: 'ext.tapir.evaluate'),
              ],
            ),
          );
        final harness = await _TestHarness.build(
          registry: registry,
          filter: McpFilterConfig.empty(),
          vmClientFactory: restartableFactory(
            clients,
            onCreate: (client) => client._evaluateScript = (_, _) =>
                InstanceRef(kind: 'Int', valueAsString: '3', id: 'objects/3'),
          ),
        );
        addTearDown(harness.dispose);
        clients.single.dispose(notifyDone: false);

        final result = await harness.connection.callTool(
          CallToolRequest(
            name: 'tapir_evaluate',
            arguments: const {'expression': '1 + 2'},
          ),
        );

        expect(result.isError, isNot(isTrue));
        expect(clients, hasLength(2));
        expect(clients.last.evaluateCalls, hasLength(1));
      },
    );
  });

  group('McpServer substrate commands under stdio', () {
    late Directory tempHome;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('dowel_mcp_logs_');
      StateFile.debugHomeOverride = tempHome.path;
    });

    tearDown(() async {
      StateFile.debugHomeOverride = null;
      await tempHome.delete(recursive: true);
    });

    test(
      'dowel_logs returns the log in the result and writes no stdout',
      () async {
        Directory('${tempHome.path}/.dowel').createSync(recursive: true);
        File('${tempHome.path}/.dowel/flutter-dev.log')
            .writeAsStringSync('line one\nline two\n');
        final registry = DowelRegistry()
          ..registerAll(<DowelCommand>[LogsCommand()], providerName: 'dowel');

        final captured = await _captureStdio(() async {
          final harness = await _TestHarness.build(
            registry: registry,
            filter: McpFilterConfig.empty(),
          );
          try {
            return await harness.connection.callTool(
              CallToolRequest(name: 'dowel_logs', arguments: const {}),
            );
          } finally {
            await harness.dispose();
          }
        });

        expect(captured.result.isError, isFalse);
        final text = (captured.result.content.single as TextContent).text;
        expect(text, contains('line one\nline two'));
        // Stdout is the JSON-RPC channel under `mcp:serve`.
        expect(captured.out, isEmpty);
      },
    );

    test('dowel_logs refuses follow instead of tailing forever', () async {
      Directory('${tempHome.path}/.dowel').createSync(recursive: true);
      File('${tempHome.path}/.dowel/flutter-dev.log')
          .writeAsStringSync('line one\n');
      final registry = DowelRegistry()
        ..registerAll(<DowelCommand>[LogsCommand()], providerName: 'dowel');
      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);

      final result = await harness.connection
          .callTool(
            CallToolRequest(
              name: 'dowel_logs',
              arguments: const {'follow': true},
            ),
          )
          .timeout(const Duration(seconds: 5));

      expect(result.isError, isTrue);
      final text = (result.content.single as TextContent).text;
      expect(text, contains('logs --follow'));
      expect(text, isNot(contains('line one')));
    });

    test(
      'dowel_tinker rejects a blank eval instead of reading stdin',
      () async {
        final registry = DowelRegistry()
          ..registerAll(<DowelCommand>[TinkerCommand()], providerName: 'dowel');

        final captured = await _captureStdio(() async {
          final harness = await _TestHarness.build(
            registry: registry,
            filter: McpFilterConfig.empty(),
          );
          try {
            return await harness.connection.callTool(
              CallToolRequest(
                name: 'dowel_tinker',
                arguments: const {'eval': '  '},
              ),
            );
          } finally {
            await harness.dispose();
          }
        });

        expect(captured.result.isError, isTrue);
        final text = (captured.result.content.single as TextContent).text;
        expect(text, contains('--eval'));
        expect(text, isNot(contains('Tinker connected')));
        expect(captured.out, isEmpty);
      },
    );

    test('array arguments reach the command as List<String>', () async {
      List<String>? received;
      final registry = DowelRegistry()
        ..registerAll(<DowelCommand>[
          _FakeSubstrateCommand(
            'start',
            'Boot the app.',
            onHandle: (ctx) async {
              received = ctx.input.option('flutter-arg') as List<String>?;
              return 0;
            },
          ),
        ], providerName: 'dowel');
      final harness = await _TestHarness.build(
        registry: registry,
        filter: McpFilterConfig.empty(),
      );
      addTearDown(harness.dispose);

      final result = await harness.connection.callTool(
        CallToolRequest(
          name: 'dowel_start',
          arguments: const {
            'flutter-arg': ['--flavor=dev', '--dart-define=TAGS=a,b'],
          },
        ),
      );

      expect(result.isError, isFalse);
      expect(received, ['--flavor=dev', '--dart-define=TAGS=a,b']);
    });
  });

  group('McpServer substrate tool schemas', () {
    test(
      'every CLI option of an allowlisted command has a schema property',
      () async {
        final registry = DowelRegistry();
        registry.registerAll(<DowelCommand>[
          StartCommand(),
          StopCommand(),
          StatusCommand(),
          LogsCommand(),
          RestartCommand(),
          ReloadCommand(),
          HotRestartCommand(),
          DoctorCommand(),
          ListCommand(registry),
          TinkerCommand(),
        ], providerName: 'dowel');
        final harness = await _TestHarness.build(
          registry: registry,
          filter: McpFilterConfig.empty(),
        );
        addTearDown(harness.dispose);

        final tools = {
          for (final tool in (await harness.connection.listTools()).tools)
            tool.name: tool,
        };
        expect(tools, hasLength(10));

        // Options a tool leaves out on purpose, because the tool cannot honour
        // them: `logs --follow` never ends, and a tool call answers only when
        // the command does.
        const cliOnly = <String, Set<String>>{
          'logs': <String>{'follow'},
        };

        for (final command in registry.all()) {
          final toolName = 'dowel_${command.name.replaceAll('-', '_')}';
          final properties = Map<String, dynamic>.from(
            (tools[toolName]!.inputSchema as Map)['properties'] as Map,
          );
          final parser = ArgParser();
          command.configure(parser);

          final skipped = cliOnly[command.name] ?? const <String>{};
          expect(
            properties.keys,
            everyElement(isNot(isIn(skipped))),
            reason: '$toolName advertises a CLI-only option',
          );
          for (final option in parser.options.values) {
            if (skipped.contains(option.name)) continue;
            final expectedType = option.isFlag
                ? 'boolean'
                : option.isMultiple
                ? 'array'
                : 'string';
            expect(
              properties[option.name]?['type'],
              expectedType,
              reason:
                  '$toolName has no `${option.name}` property of type '
                  '$expectedType',
            );
          }
          expect(
            properties.keys,
            everyElement(isIn(parser.options.keys)),
            reason: '$toolName advertises a property the CLI does not parse',
          );
        }
      },
    );
  });

  group('McpServer handshake order', () {
    test('sends no tools/list_changed before or after initialize', () async {
      final controller = StreamChannelController<String>(sync: true);
      final received = <Map<String, dynamic>>[];
      controller.foreign.stream.listen(
        (line) => received.add(jsonDecode(line) as Map<String, dynamic>),
      );
      final registry = DowelRegistry()
        ..registerAll(<DowelCommand>[
          _FakeSubstrateCommand('status', 'Print status.'),
          _FakeSubstrateCommand('doctor', 'Run checks.'),
        ], providerName: 'dowel');
      final server = McpServer.test(
        channel: controller.local,
        registry: registry,
        filter: McpFilterConfig.empty(),
        vmClientFactory: (_) => _StubVmServiceClient(),
        // A slow state read keeps initialize suspended while the pipelined
        // `initialized` notification below is handled.
        stateReader: () async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return null;
        },
      );
      addTearDown(server.shutdown);

      // A client that pipelines both messages, as a shell script driving
      // stdio does.
      controller.foreign.sink
        ..add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': <String, dynamic>{
              'protocolVersion': ProtocolVersion.latestSupported.versionString,
              'capabilities': <String, dynamic>{},
              'clientInfo': <String, dynamic>{'name': 'raw', 'version': '1'},
            },
          }),
        )
        ..add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'notifications/initialized',
          }),
        );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(received, isNotEmpty);
      expect(received.first['id'], 1);
      expect(
        received.where(
          (m) => m['method'] == 'notifications/tools/list_changed',
        ),
        isEmpty,
      );
    });
  });
}

/// Runs [body] with `stdout` and `stderr` captured, so a test can prove a
/// dispatch wrote nothing to the stream that carries JSON-RPC under stdio.
Future<({T result, String out})> _captureStdio<T>(
  Future<T> Function() body,
) async {
  final out = _CapturingStdout();
  final err = _CapturingStdout();
  final result = await IOOverrides.runZoned(
    body,
    stdout: () => out,
    stderr: () => err,
  );
  return (result: result, out: out.buffer.toString());
}

/// File-private [Stdout] fake that buffers every write for assertion.
class _CapturingStdout implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  Encoding encoding = systemEncoding;

  @override
  String lineTerminator = '\n';

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String sep = '']) =>
      buffer.writeAll(objects, sep);

  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);

  @override
  void add(List<int> data) => buffer.write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> flush() => Future<void>.value();

  @override
  Future<void> get done => Future<void>.value();

  @override
  Future<void> close() => Future<void>.value();

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  int get terminalColumns => 80;

  @override
  int get terminalLines => 24;

  @override
  IOSink get nonBlocking => this;
}

/// File-private substrate command fake for the dowel_* tool tests.
/// Skips the signature DSL boilerplate and lets the test pin an `onHandle`
/// closure that observes the dispatch path without spinning up a real
/// command implementation.
class _FakeSubstrateCommand extends DowelCommand {
  _FakeSubstrateCommand(this._name, this._description, {this.onHandle});

  final String _name;
  final String _description;
  final Future<int> Function(DowelContext)? onHandle;

  @override
  String get name => _name;

  @override
  String get description => _description;

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  Future<int> handle(DowelContext ctx) async {
    return onHandle?.call(ctx) ?? 0;
  }
}

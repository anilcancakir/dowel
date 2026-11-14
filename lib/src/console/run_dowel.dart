import 'dart:io';

import 'package:path/path.dart' as p;

import '../state/state_file.dart';
import '../commands/commands_refresh_command.dart';
import '../commands/doctor_command.dart';
import '../commands/help_command.dart';
import '../commands/hot_restart_command.dart';
import '../commands/list_command.dart';
import '../commands/logs_command.dart';
import '../commands/make_command_command.dart';
import '../commands/make_fast_cli_command.dart';
import '../commands/make_plugin_command.dart';
import '../commands/install_command.dart';
import '../commands/mcp_install_command.dart';
import '../commands/mcp_serve_command.dart';
import '../commands/mcp_uninstall_command.dart';
import '../commands/plugin_install_command.dart';
import '../commands/plugin_uninstall_command.dart';
import '../commands/plugins_refresh_command.dart';
import '../commands/reload_command.dart';
import '../commands/restart_command.dart';
import '../commands/start_command.dart';
import '../commands/status_command.dart';
import '../commands/stop_command.dart';
import '../commands/tinker_command.dart';
import 'dowel_application.dart';
import 'dowel_command.dart';
import 'dowel_command_collision_exception.dart';
import 'dowel_registry.dart';
import 'dowel_service_provider.dart';

/// Bypass list for auto-delegation.
///
/// Commands that regenerate the very files the consumer wrapper imports MUST
/// run from the substrate binary, never via delegation. Otherwise a stale or
/// broken `lib/app/_index.g.dart` / `lib/app/_plugins.g.dart` blocks the
/// wrapper from compiling, blocking the only command that can fix it.
/// `install` writes the wrapper itself, and the one fluttersdk_artisan left in
/// a migrating project imports a package that no longer resolves; `doctor`
/// must run when the wrapper is broken, since it is what reports that.
const Set<String> _bypassDelegation = <String>{
  'commands:refresh',
  'doctor',
  'install',
  'plugins:refresh',
};

/// Signature for an injected "does CWD have a consumer wrapper?" check.
///
/// A consumer wrapper is `bin/dispatcher.dart`, the name emitted by
/// `dart run dowel install`. `bin/dowel.dart` is deliberately not one: it is
/// this package's own entry point, so treating it as a wrapper would make
/// `dowel` delegate to itself.
///
/// Defaults to the real FS lookup ([defaultConsumerWrapperExists]); tests
/// inject a deterministic stub.
typedef WrapperExistsCheck = bool Function();

/// Signature for an injected wrapper-name resolver.
///
/// Returns the basename (without `.dart`) of the consumer wrapper file
/// auto-delegation should dispatch against (`'dispatcher'` for
/// `bin/dispatcher.dart`), or `null` when no wrapper is present
/// (auto-delegation skips and falls through to the standalone path).
///
/// Defaults to [defaultConsumerWrapperName] which probes the real filesystem;
/// tests inject a deterministic stub. The boolean [WrapperExistsCheck] seam
/// remains supported for existing tests; when both are injected,
/// [WrapperNameResolver] wins.
typedef WrapperNameResolver = String? Function();

/// Signature for an injected delegation strategy.
///
/// Defaults to `Process.start` against the consumer wrapper with stdio
/// inherited; tests inject a closure that records args + returns an exit
/// code without spawning a child process.
typedef DelegateStrategy = Future<int> Function(List<String> args);

/// Shared `dowel` bootstrap.
///
/// One entry point consolidates the four behaviors every dowel binary
/// (substrate `dowel`, magic's consumer wrapper, magic_logger's
/// consumer wrapper, future consumer wrappers) needs:
///
/// 1. **Auto-delegation.** When invoked from a project that ships its own
///    consumer wrapper (`bin/dispatcher.dart`), transparently re-invoke
///    `dart run :dispatcher <args>`
///    so the consumer's full provider list owns dispatch. Bypassed for
///    commands that regenerate the files the wrapper depends on (see
///    [_bypassDelegation]).
/// 2. **Standalone dispatch.** When no wrapper is present (or the call
///    bypasses delegation, or [delegateToConsumer] is `false`), register
///    builtins + [baseProviders] + auto-discovered providers and dispatch
///    via [DowelApplication].
/// 3. **Fail-fast collision.** A duplicate command between providers
///    surfaces as exit 2 (matches the substrate bin's prior behavior).
/// 4. **Generic crash handling.** Any unexpected throw surfaces as exit 3
///    (matches [DowelApplication]'s in-handle exception code).
///
/// [baseProviders] are statically known providers the caller wires by hand
/// (e.g. `[MagicDowelProvider()]` from magic's wrapper). [autoProviders]
/// is a thunk for codegen-discovered providers (the `_plugins.g.dart`
/// `autoDiscoveredProviders()` function); deferred so a missing or broken
/// codegen file does not crash callers that pass only [baseProviders].
///
/// [wrapperExists], [wrapperName], and [delegate] are seams for tests;
/// production callers leave them at their defaults. [wrapperName] supersedes
/// [wrapperExists] when both are injected: the resolver returns the wrapper
/// filename so the delegate token matches the file actually present.
///
/// When [collectMcpTools] is `true`, each provider's MCP tool descriptors are
/// registered via [DowelRegistry.registerMcpToolsFor] immediately after the
/// provider's commands are registered. Defaults to `false` so CLI invocations
/// (e.g. `dart run :dispatcher list`) pay no MCP overhead. Only the MCP server
/// entry point (`bin/mcp.dart`) passes `collectMcpTools: true`.
Future<int> runDowel(
  List<String> args, {
  List<DowelServiceProvider> baseProviders = const <DowelServiceProvider>[],
  List<DowelServiceProvider> Function()? autoProviders,
  bool delegateToConsumer = true,
  bool collectMcpTools = false,
  WrapperExistsCheck? wrapperExists,
  WrapperNameResolver? wrapperName,
  DelegateStrategy? delegate,
}) async {
  // 0. Resolve the session BEFORE anything else, so a command that runs in
  //    THIS process sees it. The flag is re-attached below when the
  //    invocation is handed to a wrapper instead: that spawns a separate
  //    Dart process, where a static on this isolate means nothing.
  args = _consumeStateFlag(args);

  // 1. Decide whether the consumer wrapper owns this invocation. Resolve
  //    the wrapper FILENAME first so the delegate token matches the file
  //    actually on disk.
  if (delegateToConsumer) {
    final resolvedName = (wrapperName ?? defaultConsumerWrapperName)();
    // Back-compat: existing tests inject `wrapperExists: () => true` against
    // tempdirs that have no on-disk wrapper. Honor the boolean override and
    // fall back to the canonical 'dispatcher' token in that case.
    final hasWrapper = wrapperExists != null
        ? wrapperExists()
        : resolvedName != null;
    final firstArg = args.isEmpty ? '' : args.first;
    final bypassed = _bypassDelegation.contains(firstArg);
    if (hasWrapper && !bypassed) {
      final token = resolvedName ?? 'dispatcher';
      // Re-attach --state: the delegate spawns a NEW process, so the child
      // resolves its own session from scratch. Dropping it here meant
      // `dowel stop --state=/x` from any consumer with a wrapper acted on
      // the auto-resolved session instead, silently.
      final String? named = StateFile.pathOverride;
      return await (delegate ?? _defaultDelegate)(<String>[
        ':$token',
        if (named != null && named.isNotEmpty) '--state=$named',
        ...args,
      ]);
    }
  }

  // 2. Standalone path: builtins + baseProviders + autoProviders.
  try {
    final registry = DowelRegistry();
    registry.registerAll(_builtinCommands(registry), providerName: 'dowel');
    for (final provider in baseProviders) {
      registry.registerProvider(provider);
      if (collectMcpTools) registry.registerMcpToolsFor(provider);
    }
    final auto = autoProviders?.call() ?? const <DowelServiceProvider>[];
    for (final provider in auto) {
      registry.registerProvider(provider);
      if (collectMcpTools) registry.registerMcpToolsFor(provider);
    }
    final app = DowelApplication(registry: registry);
    return await app.dispatch(args);
  } on DowelCommandCollisionException catch (e) {
    stderr.writeln('Fatal: $e');
    return 2;
  } catch (e, s) {
    stderr.writeln('Unexpected error: $e');
    stderr.writeln(s);
    return 3;
  }
}

/// Default wrapper presence check.
///
/// Returns `true` when `<cwd>/bin/dispatcher.dart` (the name scaffolded by
/// `dart run dowel install`) exists, which qualifies the current directory as
/// a consumer wrapper that auto-delegation should target.
///
/// [cwd] defaults to [Directory.current]; tests inject a temp-dir path to
/// drive the check deterministically without touching the host filesystem.
bool defaultConsumerWrapperExists({String? cwd}) {
  return defaultConsumerWrapperName(cwd: cwd) != null;
}

/// Default wrapper-name resolver.
///
/// Returns the basename (without `.dart`) of the consumer wrapper auto-
/// delegation should dispatch against: `'dispatcher'` when
/// `bin/dispatcher.dart` exists, `null` otherwise. `bin/dowel.dart` is never a
/// wrapper: it is this package's own entry point.
///
/// [cwd] defaults to [Directory.current]; tests inject a temp-dir path to
/// drive the check deterministically without touching the host filesystem.
String? defaultConsumerWrapperName({String? cwd}) {
  final base = cwd ?? Directory.current.path;
  if (File(p.join(base, 'bin', 'dispatcher.dart')).existsSync()) {
    return 'dispatcher';
  }
  return null;
}

/// Default delegation: `dart run :dispatcher <args>` with inherited stdio.
Future<int> _defaultDelegate(List<String> args) async {
  final result = await Process.start(
    Platform.resolvedExecutable,
    <String>['run', ...args],
    mode: ProcessStartMode.inheritStdio,
    workingDirectory: Directory.current.path,
  );
  return await result.exitCode;
}

/// Builtins shipped by `dowel` itself.
///
/// `CommandsRefreshCommand` and `PluginsRefreshCommand` ship side-by-side
/// here AND in the bypass list ([_bypassDelegation]); the bypass guarantee
/// is what lets these commands fix a broken consumer wrapper without first
/// requiring that same wrapper to compile.
List<DowelCommand> _builtinCommands(DowelRegistry registry) => <DowelCommand>[
  StartCommand(),
  StopCommand(),
  StatusCommand(),
  LogsCommand(),
  ReloadCommand(),
  HotRestartCommand(),
  RestartCommand(),
  DoctorCommand(),
  ListCommand(registry),
  HelpCommand(registry),
  MakeCommandCommand(),
  MakeFastCliCommand(),
  MakePluginCommand(),
  CommandsRefreshCommand(),
  PluginsRefreshCommand(),
  PluginInstallCommand(),
  PluginUninstallCommand(),
  InstallDowelCommand(),
  TinkerCommand(),
  McpServeCommand(),
  McpInstallCommand(),
  McpUninstallCommand(),
];

/// Pulls a leading-or-anywhere `--state=<path>` (or `--state <path>`) out of
/// [args] and records it on [StateFile].
///
/// A global flag rather than a per-command option: every connected command
/// needs it and none of them owns it. `DOWEL_STATE_FILE` covers the same
/// need for a shell that sets it once; the flag wins when both are present,
/// because it is the more specific statement of intent.
List<String> _consumeStateFlag(List<String> args) {
  final List<String> rest = <String>[];
  for (int i = 0; i < args.length; i++) {
    final String arg = args[i];
    if (arg.startsWith('--state=')) {
      StateFile.pathOverride = arg.substring('--state='.length);
      continue;
    }
    if (arg == '--state' && i + 1 < args.length) {
      StateFile.pathOverride = args[i + 1];
      i++;
      continue;
    }
    rest.add(arg);
  }
  return rest;
}

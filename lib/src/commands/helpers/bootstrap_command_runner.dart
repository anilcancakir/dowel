import 'dart:io';

import 'package:path/path.dart' as p;

/// Signature for the [Process.run] seam, injectable in tests.
///
/// Mirrors the subset of [Process.run] parameters that
/// [BootstrapCommandRunner] uses: executable, arguments, and an optional
/// workingDirectory. Tests pass a recording fake so no real subprocess spawns.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

/// Default [ProcessRunner] that delegates to [Process.run].
Future<ProcessResult> _defaultRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) {
  return Process.run(executable, arguments, workingDirectory: workingDirectory);
}

/// Outcome of a [BootstrapCommandRunner.run] attempt.
///
/// - [invoked]: a dispatcher was resolved and the bootstrap command was run
///   as a subprocess (regardless of the chained command's own exit code).
/// - [notResolvable]: no dispatcher could be resolved (no `bin/dowel` wrapper
///   and no consumer package name in `pubspec.yaml`), so nothing was spawned
///   and the caller should fall back to the one-line bootstrap hint.
enum BootstrapRunOutcome { invoked, notResolvable }

/// Result of a [BootstrapCommandRunner.run] attempt.
///
/// Carries the [outcome] plus, when a subprocess actually ran, its
/// [exitCode] and captured [stderr]. The caller uses [succeeded] to decide
/// whether the chained command completed; a non-zero exit (a stale bundle, an
/// unknown command, a scaffold error) must NOT be reported to the operator as
/// success, which is exactly what discarding the [ProcessResult] used to do.
final class BootstrapRunResult {
  /// The [invoked] outcome MUST carry an [exitCode]: a subprocess that ran
  /// always has one, and the invariant stops an incomplete result from
  /// producing operator messages like "exited with code null".
  const BootstrapRunResult({required this.outcome, this.exitCode, this.stderr})
    : assert(
        outcome != BootstrapRunOutcome.invoked || exitCode != null,
        'an invoked BootstrapRunResult must carry a subprocess exit code',
      );

  final BootstrapRunOutcome outcome;

  /// Subprocess exit code, or `null` when [outcome] is `notResolvable`
  /// (nothing was spawned).
  final int? exitCode;

  /// Captured subprocess stderr, or `null` when nothing was spawned.
  final String? stderr;

  /// True only when a subprocess ran AND exited zero.
  bool get succeeded => outcome == BootstrapRunOutcome.invoked && exitCode == 0;
}

/// Runs a plugin's declared `bootstrap_command` as a fresh dispatcher
/// subprocess after `plugin:install` registers the plugin.
///
/// The bootstrap command is a PLUGIN command that was only just written to
/// `lib/app/_plugins.g.dart` during this same install run, so it is NOT
/// loaded in the current process. A fresh dispatcher invocation is the only
/// way to reach it, hence a subprocess rather than an in-process `handle()`.
///
/// ## Dispatcher resolution
///
/// 1. Prefer `./bin/dowel <command> --non-interactive` when a `bin/dowel` wrapper
///    exists at the consumer project root (the AOT fast-CLI path).
/// 2. Otherwise `dart run <pkg>:dowel <command> --non-interactive`, deriving
///    `<pkg>` (the consumer package name) from the project's `pubspec.yaml`
///    `name:` field.
/// 3. When neither resolves, return [BootstrapRunOutcome.notResolvable] so the
///    caller can fall back to printing the bootstrap hint.
///
/// `--non-interactive` is ALWAYS forwarded so an interactive chained install
/// (e.g. `starter:install`) cannot hang waiting on stdin.
///
/// ## Constructor injection seam
///
/// ```dart
/// // Production: real subprocess
/// final runner = BootstrapCommandRunner();
///
/// // Test: recording fake
/// final runner = BootstrapCommandRunner(processRunner: myFakeRunner);
/// ```
class BootstrapCommandRunner {
  /// Creates a runner with an optional [ProcessRunner] override.
  ///
  /// [processRunner] defaults to [Process.run] from `dart:io`. Inject a fake
  /// in tests to assert the resolved command without spawning a process.
  BootstrapCommandRunner({ProcessRunner? processRunner})
    : _runner = processRunner ?? _defaultRunner;

  final ProcessRunner _runner;

  /// Resolves a dispatcher and runs `<bootstrapCommand> --non-interactive`
  /// against [projectRoot].
  ///
  /// @param bootstrapCommand  The plugin command to chain (e.g.
  ///                          `starter:install`).
  /// @param projectRoot       Absolute path to the consumer project root.
  /// @return a [BootstrapRunResult]: `invoked` (with the subprocess exit code
  ///         and captured stderr) when a dispatcher was resolved and ran;
  ///         `notResolvable` when no dispatcher could be resolved.
  Future<BootstrapRunResult> run({
    required String bootstrapCommand,
    required String projectRoot,
  }) async {
    // 1. Build the dispatcher invocation: bin/dowel fast-CLI when present,
    //    else `dart run :dispatcher`. Return early when neither is
    //    resolvable so the caller can fall back to the hint.
    final invocation = _resolveDispatcher(projectRoot, bootstrapCommand);
    if (invocation == null) {
      return const BootstrapRunResult(
        outcome: BootstrapRunOutcome.notResolvable,
      );
    }

    // 2. Run the chained command as a subprocess scoped to the consumer root,
    //    and surface its exit code + stderr so the caller can tell success
    //    from a silent failure (a stale bundle, an unknown command, or a
    //    scaffold error must not be reported to the operator as success).
    final result = await _runner(
      invocation.executable,
      invocation.arguments,
      workingDirectory: projectRoot,
    );
    return BootstrapRunResult(
      outcome: BootstrapRunOutcome.invoked,
      exitCode: result.exitCode,
      stderr: result.stderr?.toString(),
    );
  }

  /// Resolves the dispatcher executable + argument list, or `null` when no
  /// dispatcher is available.
  _DispatcherInvocation? _resolveDispatcher(
    String projectRoot,
    String bootstrapCommand,
  ) {
    const nonInteractive = '--non-interactive';

    // bin/dowel fast-CLI wrapper takes precedence when present.
    if (File(p.join(projectRoot, 'bin', 'dowel')).existsSync()) {
      return _DispatcherInvocation(
        executable: './bin/dowel',
        arguments: <String>[bootstrapCommand, nonInteractive],
      );
    }

    // Fall back to `dart run :dispatcher` when the consumer scaffold exists
    // (Windows, or a failed fast-CLI build). bin/dowel.dart is dowel's own
    // entry point and never stands in for a consumer wrapper.
    if (File(p.join(projectRoot, 'bin', 'dispatcher.dart')).existsSync()) {
      return _DispatcherInvocation(
        executable: 'dart',
        arguments: <String>[
          'run',
          ':dispatcher',
          bootstrapCommand,
          nonInteractive,
        ],
      );
    }

    return null;
  }
}

/// Resolved dispatcher executable + argument list.
class _DispatcherInvocation {
  const _DispatcherInvocation({
    required this.executable,
    required this.arguments,
  });

  final String executable;
  final List<String> arguments;
}

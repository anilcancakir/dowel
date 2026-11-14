import 'dart:io';

import 'package:dowel/src/commands/helpers/bootstrap_command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Records every [ProcessRunner] call so tests can assert on executable, args,
/// and working directory without spawning a real subprocess.
class _RecordingRunner {
  String? executable;
  List<String>? arguments;
  String? workingDirectory;

  ProcessResult returnResult = ProcessResult(0, 0, '', '');

  Future<ProcessResult> call(
    String exe,
    List<String> args, {
    String? workingDirectory,
  }) async {
    executable = exe;
    arguments = args;
    this.workingDirectory = workingDirectory;
    return returnResult;
  }
}

void main() {
  group('BootstrapCommandRunner — dispatcher resolution', () {
    test('prefers ./bin/dowel when the wrapper exists', () async {
      final root = Directory.systemTemp.createTempSync('bootstrap_dowel_');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(p.join(root.path, 'bin')).createSync(recursive: true);
      File(p.join(root.path, 'bin', 'dowel')).writeAsStringSync('#!/bin/sh\n');

      final runner = _RecordingRunner();
      final result = await BootstrapCommandRunner(processRunner: runner.call)
          .run(bootstrapCommand: 'starter:install', projectRoot: root.path);

      expect(result.outcome, BootstrapRunOutcome.invoked);
      expect(runner.executable, './bin/dowel');
      expect(
        runner.arguments,
        equals(<String>['starter:install', '--non-interactive']),
      );
      expect(runner.workingDirectory, root.path);
    });

    test('falls back to dart run :dispatcher when bin/dowel is absent but '
        'bin/dispatcher.dart exists', () async {
      final root = Directory.systemTemp.createTempSync('bootstrap_dartrun_');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(p.join(root.path, 'bin')).createSync(recursive: true);
      File(p.join(root.path, 'bin', 'dispatcher.dart'))
          .writeAsStringSync('void main() {}\n');

      final runner = _RecordingRunner();
      final result = await BootstrapCommandRunner(processRunner: runner.call)
          .run(bootstrapCommand: 'starter:install', projectRoot: root.path);

      expect(result.outcome, BootstrapRunOutcome.invoked);
      expect(runner.executable, 'dart');
      expect(
        runner.arguments,
        equals(<String>[
          'run',
          ':dispatcher',
          'starter:install',
          '--non-interactive',
        ]),
      );
      expect(runner.workingDirectory, root.path);
    });

    test('reports notResolvable when neither bin/dowel nor bin/dispatcher.dart '
        'exists, even with a pubspec and a bin/dowel.dart', () async {
      final root = Directory.systemTemp.createTempSync('bootstrap_unresolv_');
      addTearDown(() => root.deleteSync(recursive: true));
      // bin/dowel.dart is dowel's own entry point, never a consumer wrapper.
      File(p.join(root.path, 'pubspec.yaml'))
          .writeAsStringSync('name: my_app\n');
      Directory(p.join(root.path, 'bin')).createSync(recursive: true);
      File(p.join(root.path, 'bin', 'dowel.dart'))
          .writeAsStringSync('void main() {}\n');

      final runner = _RecordingRunner();
      final result = await BootstrapCommandRunner(processRunner: runner.call)
          .run(bootstrapCommand: 'starter:install', projectRoot: root.path);

      expect(result.outcome, BootstrapRunOutcome.notResolvable);
      expect(
        runner.executable,
        isNull,
        reason: 'no dispatcher means the runner is never invoked',
      );
    });

    test('surfaces the subprocess exit code and stderr on failure', () async {
      final root = Directory.systemTemp.createTempSync('bootstrap_fail_');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(p.join(root.path, 'bin')).createSync(recursive: true);
      File(p.join(root.path, 'bin', 'dowel')).writeAsStringSync('#!/bin/sh\n');

      final runner = _RecordingRunner()
        ..returnResult = ProcessResult(
          0,
          64,
          '',
          'Unknown command: starter:install',
        );
      final result = await BootstrapCommandRunner(processRunner: runner.call)
          .run(bootstrapCommand: 'starter:install', projectRoot: root.path);

      expect(result.outcome, BootstrapRunOutcome.invoked);
      expect(result.succeeded, isFalse);
      expect(result.exitCode, 64);
      expect(result.stderr, contains('Unknown command'));
    });

    test('reports succeeded when the subprocess exits zero', () async {
      final root = Directory.systemTemp.createTempSync('bootstrap_ok_');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(p.join(root.path, 'bin')).createSync(recursive: true);
      File(p.join(root.path, 'bin', 'dowel')).writeAsStringSync('#!/bin/sh\n');

      final runner = _RecordingRunner()
        ..returnResult = ProcessResult(0, 0, '', '');
      final result = await BootstrapCommandRunner(processRunner: runner.call)
          .run(bootstrapCommand: 'starter:install', projectRoot: root.path);

      expect(result.succeeded, isTrue);
      expect(result.exitCode, 0);
    });

    test('always forwards --non-interactive to the chained command', () async {
      final root = Directory.systemTemp.createTempSync('bootstrap_noninter_');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(p.join(root.path, 'bin')).createSync(recursive: true);
      File(p.join(root.path, 'bin', 'dowel')).writeAsStringSync('#!/bin/sh\n');

      final runner = _RecordingRunner();
      await BootstrapCommandRunner(processRunner: runner.call)
          .run(bootstrapCommand: 'logger:install', projectRoot: root.path);

      expect(runner.arguments, contains('--non-interactive'));
    });

    test('the default runner really spawns the subprocess', () {
      // Every other case here injects a recording fake, so the one line that
      // reaches Process.run has never run under test. It is the line that
      // decides whether a chained install happens at all.
      final Directory root = Directory.systemTemp.createTempSync(
        'dowel_bootstrap_real_',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: demo_app\n');
      Directory('${root.path}/bin').createSync();
      File('${root.path}/bin/dispatcher.dart')
          .writeAsStringSync('void main() {}\n');

      // No bin/dowel but a bin/dispatcher.dart, so it resolves to `dart run
      // :dispatcher ...`, which fails fast in a directory with no resolved
      // package. The assertion is that a subprocess ran and its code came
      // back, not that the chained command succeeded.
      final runner = BootstrapCommandRunner();

      expect(
        runner.run(bootstrapCommand: 'demo:install', projectRoot: root.path),
        completion(
          isA<BootstrapRunResult>()
              .having(
                (BootstrapRunResult r) => r.outcome,
                'outcome',
                BootstrapRunOutcome.invoked,
              )
              .having(
                (BootstrapRunResult r) => r.exitCode,
                'exitCode',
                isNotNull,
              ),
        ),
      );
    });
  });
}

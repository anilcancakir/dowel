import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../console/dowel_command.dart';
import '../console/dowel_context.dart';
import '../console/command_boot.dart';
import '../helpers/file_helper.dart';
import '../stubs/stub_loader.dart';

/// `make:fast-cli`: scaffold a POSIX shell wrapper (`bin/dowel`) that compiles
/// `bin/dispatcher.dart` into an AOT binary via `dart build cli`, cached at
/// `.dowel/cli-bundle/`. Wrapper auto-detects staleness and re-compiles
/// transparently. Result: ~50ms startup for `./bin/dowel <cmd>` vs ~3s for
/// `dart run dowel <cmd>`.
///
/// Idempotent: skips `bin/dowel` when it already exists; pass `--force` to
/// overwrite.
///
/// POSIX-only V1 (macOS + Linux); Windows support is deferred.
final class MakeFastCliCommand extends DowelCommand {
  @override
  String get signature => 'make:fast-cli '
      '{--force : Overwrite bin/dowel even when it already exists}';

  @override
  String get description =>
      'Scaffold a fast-CLI wrapper (bin/dowel) plus AOT-compiled dowel '
      'binary, giving local invocations a ~50ms startup vs ~3s with '
      'dart run.';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  Future<int> handle(DowelContext ctx) async {
    final force = ctx.input.option('force') as bool? ?? false;
    final root = FileHelper.findProjectRoot();
    return scaffoldInto(root: root, force: force, ctx: ctx);
  }

  /// Test seam: replace with a [_RecordingRunner]-style callable in tests.
  ///
  /// Signature matches the [Process.run] overload subset used by this command
  /// (executable + args list + optional workingDirectory). Tests inject a fake
  /// to avoid spinning up real child processes.
  @visibleForTesting
  static Future<ProcessResult> Function(
    String,
    List<String>, {
    String? workingDirectory,
  }) processRunner = Process.run;

  /// Testable entry point. Writes `bin/dowel`, sets executable bit, patches
  /// `.gitignore`, compiles the AOT bundle, and writes the build stamp.
  ///
  /// Idempotent across all phases:
  /// - `bin/dowel` write skips when the target already exists unless [force].
  /// - `.gitignore` append is a no-op when `.dowel/` is already present.
  /// - AOT compile is skipped on subsequent runs when `bin/dowel` exists and
  ///   [force] is false (stamp is written only on first compile).
  ///
  /// Public composition seam: called by both the `make:fast-cli` CLI entry
  /// (via [handle]) and by `InstallDowelCommand.scaffoldInto` (auto-chain at the
  /// end of the canonical `install` flow). The previous `@visibleForTesting`
  /// gate was lifted so cross-command production composition does not trip
  /// `invalid_use_of_visible_for_testing_member`.
  static Future<int> scaffoldInto({
    required String root,
    required bool force,
    required DowelContext ctx,
  }) async {
    // 1. Validate pubspec.yaml — confirms we are inside a Dart/Flutter project.
    final pubspecPath = p.join(root, 'pubspec.yaml');
    if (!File(pubspecPath).existsSync()) {
      ctx.output.error(
        'Could not find pubspec.yaml at $pubspecPath. '
        'Run `make:fast-cli` from a Dart/Flutter project root.',
      );
      return 1;
    }

    // 2. Validate bin/dispatcher.dart — the consumer wrapper must exist before
    //    we scaffold the fast-CLI layer on top of it.
    final dowelBinPath = p.join(root, 'bin', 'dispatcher.dart');
    if (!File(dowelBinPath).existsSync()) {
      ctx.output.error('bin/dispatcher.dart not found. Run `install` first.');
      return 1;
    }

    // 3. Write bin/dowel from stub; skip when already present unless forced.
    final binDowelPath = p.join(root, 'bin', 'dowel');
    final wroteWrapper = _shouldWrite(binDowelPath, force);
    if (wroteWrapper) {
      final raw = StubLoader.load('bin_dowel.sh');
      FileHelper.writeFile(binDowelPath, raw);
      ctx.output.success('Created: $binDowelPath');
    } else {
      ctx.output.info('Skipped (exists): $binDowelPath');
    }

    // 4. Set the executable bit on bin/dowel so the user can invoke ./bin/dowel
    //    directly without a leading `sh`. Warn on non-zero exit (Windows may
    //    not have chmod; V1 POSIX-only doctrine means this should succeed on
    //    macOS and Linux).
    if (wroteWrapper) {
      final chmodResult = await processRunner('chmod', ['+x', binDowelPath]);
      if (chmodResult.exitCode != 0) {
        ctx.output.warning(
          'chmod +x $binDowelPath failed (exit ${chmodResult.exitCode}). '
          'Set the executable bit manually before running ./bin/dowel.',
        );
      }
    }

    // 5. Patch .gitignore: append `.dowel/` if not already present.
    //    Creates the file from scratch when it does not exist yet.
    final gitignorePath = p.join(root, '.gitignore');
    final gitignoreFile = File(gitignorePath);
    if (gitignoreFile.existsSync()) {
      final existing = gitignoreFile.readAsStringSync();
      if (!existing.contains('.dowel/')) {
        gitignoreFile.writeAsStringSync(
          existing.endsWith('\n')
              ? '$existing.dowel/\n'
              : '$existing\n.dowel/\n',
        );
      }
    } else {
      gitignoreFile.writeAsStringSync('.dowel/\n');
    }

    // When bin/dowel was not rewritten (idempotent skip), skip the expensive
    // compile so repeated runs do not trigger a multi-second dart build cli.
    if (!wroteWrapper) {
      ctx.output.success(
        'dowel: ready. Run ./bin/dowel <cmd> for a ~50ms startup.',
      );
      return 0;
    }

    // 6. Compute pubspec.lock SHA256 for the build stamp.
    final lockFile = File(p.join(root, 'pubspec.lock'));
    final lockBytes =
        lockFile.existsSync() ? lockFile.readAsBytesSync() : <int>[];
    final pubspecLockSha = sha256.convert(lockBytes).toString();

    // 7. Resolve the Dart SDK version for the build stamp.
    final versionResult = await processRunner('dart', ['--version']);
    final versionOutput = (versionResult.stdout as String).isNotEmpty
        ? versionResult.stdout as String
        : versionResult.stderr as String;
    final versionMatch = RegExp(r'(\d+\.\d+[\.\d]*)').firstMatch(versionOutput);
    final dartSdkVer = versionMatch?.group(1) ?? 'unknown';

    // 8. Compile the AOT bundle via dart build cli. Forward stdout + stderr
    //    so the user sees compiler progress. On non-zero exit, report the
    //    error details and surface a non-zero exit code.
    final buildResult = await processRunner(
        'dart',
        [
          'build',
          'cli',
          '-t',
          'bin/dispatcher.dart',
          '-o',
          '.dowel/cli-bundle',
        ],
        workingDirectory: root);
    if (buildResult.stdout is String &&
        (buildResult.stdout as String).isNotEmpty) {
      ctx.output.writeln(buildResult.stdout as String);
    }
    if (buildResult.stderr is String &&
        (buildResult.stderr as String).isNotEmpty) {
      ctx.output.writeln(buildResult.stderr as String);
    }
    if (buildResult.exitCode != 0) {
      ctx.output.error(
        'dart build cli failed (exit ${buildResult.exitCode}). '
        'Output: ${buildResult.stderr}',
      );
      return 1;
    }

    // 9. Write stamp atomically (.tmp + rename) so a partial compile never
    //    leaves a stale stamp. Mirrors InstallTransaction.commit + StateFile.write
    //    atomic-write pattern used throughout dowel.
    final stampContent = '$pubspecLockSha:$dartSdkVer';
    final stampPath = p.join(root, '.dowel', 'build.stamp');
    final tmp = File('$stampPath.tmp');
    tmp.parent.createSync(recursive: true);
    tmp.writeAsStringSync(stampContent);
    tmp.renameSync(stampPath);

    // 10. Signal success to the user.
    ctx.output
        .success('dowel: ready. Run ./bin/dowel <cmd> for a ~50ms startup.');
    return 0;
  }

  /// Returns true when [path] does not exist OR [force] is set.
  static bool _shouldWrite(String path, bool force) {
    if (force) return true;
    return !File(path).existsSync();
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:test/test.dart';

/// Constant warning message emitted when a stale `.mcp.json` entry is found.
String _staleMcpWarning(String key) =>
    'WARN: Stale MCP entry detected. Pre-upgrade .mcp.json points at the '
    'removed fluttersdk_mcp package. Delete the "$key" entry from '
    '.mcp.json, then run: ./bin/dowel mcp:install (or: '
    'dart run dowel mcp:install).';

/// Advisory warning emitted when `.mcp.json` still uses the pre-Bug-B
/// `fluttersdk_artisan:mcp` args shape. Mirrors the production constant in
/// `lib/src/commands/doctor_command.dart`; kept in sync manually.
String _preFixMcpWarning(String key) =>
    'WARN: Pre-fix MCP entry detected. Your .mcp.json still uses the '
    'fluttersdk_artisan:mcp args shape from before Bug B was fixed. '
    'Delete the "$key" entry from .mcp.json, then run: '
    './bin/dowel mcp:install (or: dart run dowel mcp:install).';

/// Advisory warning emitted when `.mcp.json` still has the `fluttersdk` server
/// key that fluttersdk_artisan's `mcp:install` wrote, whatever its args.
/// Mirrors the production constant in `lib/src/commands/doctor_command.dart`.
const _oldKeyMcpWarning =
    'WARN: Old MCP entry detected. Your .mcp.json still has the "fluttersdk" '
    'server that fluttersdk_artisan wrote, and that package no longer exists. '
    'Delete the "fluttersdk" entry from .mcp.json, then run: '
    './bin/dowel mcp:install (or: dart run dowel mcp:install).';

void main() {
  group('DoctorCommand', () {
    test('metadata: name=doctor, boot=none', () {
      final command = DoctorCommand();

      expect(command.name, 'doctor');
      expect(command.boot, CommandBoot.none);
      expect(command.description, isNotEmpty);
    });

    test('handle runs preflight checks and returns 0 or 1', () async {
      final command = DoctorCommand();
      final output = BufferedOutput();
      final ctx = DowelContext.bare(MapInput(const {}), output);

      final code = await command.handle(ctx);

      // Cannot assert pass/fail in arbitrary CI; only that the contract holds.
      expect(code, anyOf(0, 1));
      expect(output.content, contains('flutter --version'));
      expect(output.content, contains('dart --version'));
      expect(output.content, contains('port 3100'));
    });

    test('output lines start with checkmark or cross', () async {
      final command = DoctorCommand();
      final output = BufferedOutput();
      final ctx = DowelContext.bare(MapInput(const {}), output);

      await command.handle(ctx);

      // Doctor can emit advisory warning lines (stale .mcp.json, CDP SDK
      // upgrade) that do not start with ✓/✗; filter to the check rows only
      // and assert against those. The four hard checks must always show up.
      final checkLines = output.content
          .trim()
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.startsWith('✓') || l.startsWith('✗'))
          .toList();
      expect(checkLines, hasLength(4));
    });

    test('runs end-to-end without throwing', () async {
      final command = DoctorCommand();
      final ctx = DowelContext.bare(MapInput(const {}), BufferedOutput());

      await expectLater(command.handle(ctx), completes);
    });

    // -------------------------------------------------------------------------
    // Stale .mcp.json detection
    // -------------------------------------------------------------------------

    group('stale .mcp.json detection', () {
      late Directory tempDir;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('doctor_command_test_');
      });

      tearDown(() async {
        await tempDir.delete(recursive: true);
      });

      test(
          '.mcp.json with fluttersdk_mcp:server in args emits stale entry warning',
          () async {
        // Seed a .mcp.json that references the old fluttersdk_mcp:server entry.
        final mcpJson = File('${tempDir.path}/.mcp.json');
        await mcpJson.writeAsString('''
{
  "mcpServers": {
    "fluttersdk": {
      "command": "dart",
      "args": ["run", "fluttersdk_mcp:server"]
    }
  }
}
''');

        final command = DoctorCommand(workingDir: tempDir.path);
        final output = BufferedOutput();
        final ctx = DowelContext.bare(MapInput(const {}), output);

        await command.handle(ctx);

        expect(output.content, contains(_staleMcpWarning('fluttersdk')));
      });

      test(
          '.mcp.json with pre-fix fluttersdk_artisan:mcp entry emits pre-fix advisory',
          () async {
        // Seed a .mcp.json with the pre-Bug-B fluttersdk_artisan:mcp args shape.
        // Post-Step-8 this DOES emit _preFixMcpWarning; _staleMcpWarning still
        // must NOT appear because that is the legacy fluttersdk_mcp:server shape.
        final mcpJson = File('${tempDir.path}/.mcp.json');
        await mcpJson.writeAsString('''
{
  "mcpServers": {
    "fluttersdk": {
      "command": "dart",
      "args": ["run", "fluttersdk_artisan:mcp"]
    }
  }
}
''');

        final command = DoctorCommand(workingDir: tempDir.path);
        final output = BufferedOutput();
        final ctx = DowelContext.bare(MapInput(const {}), output);

        await command.handle(ctx);

        expect(output.content, isNot(contains(_staleMcpWarning('fluttersdk'))));
        expect(output.content, contains(_preFixMcpWarning('fluttersdk')));
      });

      test('a fluttersdk entry in any shape emits the old-entry warning',
          () async {
        // 0.0.20 wrote the fluttersdk key with `./bin/fsa mcp:serve` or
        // `dart run :dispatcher mcp:serve`; neither shape names a removed
        // package, so only the key gives it away.
        final mcpJson = File('${tempDir.path}/.mcp.json');
        await mcpJson.writeAsString('''
{
  "mcpServers": {
    "fluttersdk": {
      "command": "./bin/fsa",
      "args": ["mcp:serve"]
    }
  }
}
''');

        final command = DoctorCommand(workingDir: tempDir.path);
        final output = BufferedOutput();
        final ctx = DowelContext.bare(MapInput(const {}), output);

        await command.handle(ctx);

        expect(output.content, contains(_oldKeyMcpWarning));
        expect(output.content, isNot(contains(_staleMcpWarning('fluttersdk'))));
        expect(
            output.content, isNot(contains(_preFixMcpWarning('fluttersdk'))));
      });

      test('the warning names the key the stale entry really has', () async {
        final mcpJson = File('${tempDir.path}/.mcp.json');
        await mcpJson.writeAsString('''
{
  "mcpServers": {
    "old-tools": {
      "command": "dart",
      "args": ["run", "fluttersdk_mcp:server"]
    }
  }
}
''');

        final command = DoctorCommand(workingDir: tempDir.path);
        final output = BufferedOutput();
        final ctx = DowelContext.bare(MapInput(const {}), output);

        await command.handle(ctx);

        expect(output.content, contains(_staleMcpWarning('old-tools')));
        expect(
            output.content, isNot(contains('Delete the "fluttersdk" entry')));
      });

      test('a dowel entry alone emits no warning', () async {
        final mcpJson = File('${tempDir.path}/.mcp.json');
        await mcpJson.writeAsString('''
{
  "mcpServers": {
    "dowel": {
      "command": "./bin/dowel",
      "args": ["mcp:serve"]
    }
  }
}
''');

        final command = DoctorCommand(workingDir: tempDir.path);
        final output = BufferedOutput();
        final ctx = DowelContext.bare(MapInput(const {}), output);

        await command.handle(ctx);

        expect(output.content, isNot(contains(_oldKeyMcpWarning)));
        expect(output.content, isNot(contains('WARN: Old MCP entry')));
      });

      test('no .mcp.json at workingDir emits no stale warning', () async {
        // tempDir has no .mcp.json file.
        final command = DoctorCommand(workingDir: tempDir.path);
        final output = BufferedOutput();
        final ctx = DowelContext.bare(MapInput(const {}), output);

        await command.handle(ctx);

        expect(output.content, isNot(contains(_staleMcpWarning('fluttersdk'))));
      });

      test('stale .mcp.json does not change doctor exit code', () async {
        // Doctor exit code must not be affected by the advisory warning alone.
        // We run two instances: one without stale entry, one with stale entry,
        // both pointing at an empty dir (same hard-check environment). Their
        // exit codes must match.
        final mcpJson = File('${tempDir.path}/.mcp.json');
        await mcpJson.writeAsString('''
{
  "mcpServers": {
    "fluttersdk": {
      "command": "dart",
      "args": ["run", "fluttersdk_mcp:server"]
    }
  }
}
''');

        final withStale = DoctorCommand(workingDir: tempDir.path);
        final withoutStale = DoctorCommand(workingDir: tempDir.path);

        // Remove the file between runs to test clean vs stale.
        final codeWithStale = await withStale.handle(
          DowelContext.bare(MapInput(const {}), BufferedOutput()),
        );
        await mcpJson.delete();
        final codeWithoutStale = await withoutStale.handle(
          DowelContext.bare(MapInput(const {}), BufferedOutput()),
        );

        expect(codeWithStale, equals(codeWithoutStale));
      });

      test(
          'pre-fix fluttersdk_artisan:mcp .mcp.json does not change doctor exit code',
          () async {
        // The pre-fix advisory (_preFixMcpWarning) must be advisory-only and
        // must NOT affect the doctor exit code. Mirror the stale-entry
        // exit-code-stability pattern above but seed the fluttersdk_artisan:mcp
        // args shape instead of the legacy fluttersdk_mcp:server shape.
        final mcpJson = File('${tempDir.path}/.mcp.json');
        await mcpJson.writeAsString('''
{
  "mcpServers": {
    "fluttersdk": {
      "command": "dart",
      "args": ["run", "fluttersdk_artisan:mcp"]
    }
  }
}
''');

        final withPreFix = DoctorCommand(workingDir: tempDir.path);
        final withoutPreFix = DoctorCommand(workingDir: tempDir.path);

        // Remove the file between runs to compare advisory-present vs absent.
        final codeWithPreFix = await withPreFix.handle(
          DowelContext.bare(MapInput(const {}), BufferedOutput()),
        );
        await mcpJson.delete();
        final codeWithoutPreFix = await withoutPreFix.handle(
          DowelContext.bare(MapInput(const {}), BufferedOutput()),
        );

        expect(codeWithPreFix, equals(codeWithoutPreFix));
      });
    });

    // -------------------------------------------------------------------------
    // Flutter SDK version check
    // -------------------------------------------------------------------------

    group('_checkFlutterSdkVersion', () {
      /// Builds a fake [ProcessResult] with the given frameworkVersion in JSON.
      ProcessResult fakeVersionResult(String version) => ProcessResult(
            0,
            0,
            jsonEncode({'frameworkVersion': version}),
            '',
          );

      setUp(() {
        // Reset to real runner after each test.
        addTearDown(
          () => DoctorCommand.doctorFlutterRunner =
              (exe, args) => Process.run(exe, args),
        );
      });

      test('version 3.30.0 returns true (exactly at minimum)', () async {
        DoctorCommand.doctorFlutterRunner =
            (_, __) async => fakeVersionResult('3.30.0');

        final result = await DoctorCommand.checkFlutterSdkVersionForTest();

        expect(result, isTrue);
      });

      test('version 3.29.0 returns false (below minimum)', () async {
        DoctorCommand.doctorFlutterRunner =
            (_, __) async => fakeVersionResult('3.29.0');

        final result = await DoctorCommand.checkFlutterSdkVersionForTest();

        expect(result, isFalse);
      });

      test('version 4.0.0 returns true (above minimum)', () async {
        DoctorCommand.doctorFlutterRunner =
            (_, __) async => fakeVersionResult('4.0.0');

        final result = await DoctorCommand.checkFlutterSdkVersionForTest();

        expect(result, isTrue);
      });

      test(
          'beta channel string 3.30.0-1.0.pre is accepted (parser strips suffix '
          'to stay aligned with StartCommand.compareSemver)', () async {
        DoctorCommand.doctorFlutterRunner =
            (_, __) async => fakeVersionResult('3.30.0-1.0.pre');

        final result = await DoctorCommand.checkFlutterSdkVersionForTest();

        expect(result, isTrue);
      });

      test('malformed JSON output returns false (graceful parse failure)',
          () async {
        DoctorCommand.doctorFlutterRunner =
            (_, __) async => ProcessResult(0, 0, 'not-json-at-all', '');

        final result = await DoctorCommand.checkFlutterSdkVersionForTest();

        expect(result, isFalse);
      });

      test('flutter binary missing (exception thrown) returns false', () async {
        DoctorCommand.doctorFlutterRunner = (_, __) async =>
            throw ProcessException('flutter', ['--version', '--machine'],
                'No such file or directory', 2);

        final result = await DoctorCommand.checkFlutterSdkVersionForTest();

        expect(result, isFalse);
      });

      test(
          'when SDK check fails, doctor exit code is 1 and upgrade warning is emitted',
          () async {
        // Inject a runner that pretends flutter version is below minimum.
        DoctorCommand.doctorFlutterRunner =
            (_, __) async => fakeVersionResult('3.10.0');

        final output = BufferedOutput();
        final ctx = DowelContext.bare(MapInput(const {}), output);
        final command = DoctorCommand(workingDir: Directory.systemTemp.path);

        final code = await command.handle(ctx);

        expect(code, equals(1));
        expect(
            output.content, contains(DoctorCommand.cdpUpgradeWarningForTest));
      });

      test('when SDK check passes, no upgrade warning is emitted', () async {
        DoctorCommand.doctorFlutterRunner =
            (_, __) async => fakeVersionResult('3.30.0');

        final output = BufferedOutput();
        final ctx = DowelContext.bare(MapInput(const {}), output);
        final command = DoctorCommand(workingDir: Directory.systemTemp.path);

        await command.handle(ctx);

        expect(
          output.content,
          isNot(contains(DoctorCommand.cdpUpgradeWarningForTest)),
        );
      });
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Helper that fakes a `lib/app/` directory inside an [InMemoryFs] by
/// pre-writing a sentinel file the test command's `directoryExists` seam can
/// observe via the same fs instance.
///
/// @param fs           In-memory fs that backs the test.
/// @param projectRoot  Project root path used by the command under test.
/// @return The sentinel file path written so callers can pass it through
///         their own predicates if needed.
String _seedLibApp(InMemoryFs fs, String projectRoot) {
  final sentinel = '$projectRoot/lib/app/.keep';
  fs.writeAsString(sentinel, '');
  return sentinel;
}

/// Builds a default [DowelContext] with a [BufferedOutput] suitable for
/// inspecting command output in assertions.
///
/// @return A bare [DowelContext] with empty input and a buffered output.
DowelContext _ctx() {
  return DowelContext.bare(
    MapInput(const <String, dynamic>{}),
    BufferedOutput(),
  );
}

/// Wraps construction of the command under test with the in-memory seams the
/// tests need to drive it without touching the host filesystem.
///
/// @param fs           In-memory file system holding plugins.json + generated output.
/// @param projectRoot  Project root the command operates against.
/// @return A configured [PluginsRefreshCommand].
PluginsRefreshCommand _cmd(InMemoryFs fs, String projectRoot) {
  return PluginsRefreshCommand(
    fs: fs,
    projectRoot: projectRoot,
    directoryExists: (absDir) => fs.listSync(absDir).isNotEmpty,
  );
}

void main() {
  group('PluginsRefreshCommand metadata', () {
    final cmd = PluginsRefreshCommand();

    test('declares signature plugins:refresh', () {
      expect(cmd.name, 'plugins:refresh');
    });

    test('declares CommandBoot.none', () {
      expect(cmd.boot, CommandBoot.none);
    });

    test('description mentions lib/app/_plugins.g.dart', () {
      expect(cmd.description, contains('_plugins.g.dart'));
    });

    test('extends DowelCommand', () {
      expect(cmd, isA<DowelCommand>());
    });
  });

  group('PluginsRefreshCommand.handle()', () {
    test('empty registry emits empty providers list', () async {
      final fs = InMemoryFs();
      _seedLibApp(fs, '/proj');

      final code = await _cmd(fs, '/proj').handle(_ctx());
      final generated = fs.readAsString('/proj/lib/app/_plugins.g.dart');

      expect(code, 0);
      expect(
        generated,
        contains('List<DowelServiceProvider> autoDiscoveredProviders()'),
      );
      expect(generated, contains('return <DowelServiceProvider>[];'));
      // Header pinned to the regenerate hint so users know what to run.
      expect(generated, contains('GENERATED'));
      expect(generated, contains('plugins:refresh'));
      // Empty registry => no plugin import lines beyond the framework barrel.
      expect(generated, contains("import 'package:dowel/dowel.dart';"));
      // No tmp leftover after atomic rename.
      expect(fs.exists('/proj/lib/app/_plugins.g.dart.tmp'), isFalse);
    });

    test('single plugin emits one import + one constructor call', () async {
      final fs = InMemoryFs();
      _seedLibApp(fs, '/proj');
      fs.writeAsString(
        '/proj/.dowel/plugins.json',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'plugins': [
            <String, dynamic>{
              'name': 'magic_logger',
              'providerImport': 'package:magic_logger/cli.dart',
              'providerClass': 'MagicLoggerDowelProvider',
              'registeredAt': '2026-05-18T09:00:00.000Z',
            },
          ],
        }),
      );

      final code = await _cmd(fs, '/proj').handle(_ctx());
      final generated = fs.readAsString('/proj/lib/app/_plugins.g.dart');

      expect(code, 0);
      expect(
        generated,
        contains(
          "import 'package:magic_logger/cli.dart' show MagicLoggerDowelProvider;",
        ),
      );
      expect(
        generated,
        contains('return <DowelServiceProvider>[MagicLoggerDowelProvider()];'),
      );
    });

    test('multiple plugins are sorted alphabetically by providerClass',
        () async {
      final fs = InMemoryFs();
      _seedLibApp(fs, '/proj');
      fs.writeAsString(
        '/proj/.dowel/plugins.json',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'plugins': [
            <String, dynamic>{
              'name': 'z_logger',
              'providerImport': 'package:z_logger/cli.dart',
              'providerClass': 'ZLoggerDowelProvider',
              'registeredAt': '2026-05-18T09:00:00.000Z',
            },
            <String, dynamic>{
              'name': 'a_logger',
              'providerImport': 'package:a_logger/cli.dart',
              'providerClass': 'ALoggerDowelProvider',
              'registeredAt': '2026-05-18T09:01:00.000Z',
            },
          ],
        }),
      );

      final code = await _cmd(fs, '/proj').handle(_ctx());
      final generated = fs.readAsString('/proj/lib/app/_plugins.g.dart');

      expect(code, 0);
      final aIdx = generated.indexOf('ALoggerDowelProvider');
      final zIdx = generated.indexOf('ZLoggerDowelProvider');
      expect(aIdx, greaterThan(0));
      expect(zIdx, greaterThan(aIdx),
          reason: 'A* must precede Z* in deterministic output');
    });

    test('two plugins sharing providerClass hard-errors with both names',
        () async {
      final fs = InMemoryFs();
      _seedLibApp(fs, '/proj');
      fs.writeAsString(
        '/proj/.dowel/plugins.json',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'plugins': [
            <String, dynamic>{
              'name': 'logger_a',
              'providerImport': 'package:logger_a/cli.dart',
              'providerClass': 'SameClassProvider',
              'registeredAt': '2026-05-18T09:00:00.000Z',
            },
            <String, dynamic>{
              'name': 'logger_b',
              'providerImport': 'package:logger_b/cli.dart',
              'providerClass': 'SameClassProvider',
              'registeredAt': '2026-05-18T09:01:00.000Z',
            },
          ],
        }),
      );

      await expectLater(
        _cmd(fs, '/proj').handle(_ctx()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('SameClassProvider'),
              contains('logger_a'),
              contains('logger_b'),
            ),
          ),
        ),
      );
    });

    test('missing lib/app/ directory hard-errors with bootstrap hint',
        () async {
      final fs = InMemoryFs();
      // NOTE: no _seedLibApp call so lib/app/ does not exist.
      fs.writeAsString(
        '/proj/.dowel/plugins.json',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'plugins': <dynamic>[],
        }),
      );

      await expectLater(
        _cmd(fs, '/proj').handle(_ctx()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('lib/app/'),
              contains('dowel install'),
            ),
          ),
        ),
      );
    });

    test('codegen is byte-identical across two consecutive runs (idempotent)',
        () async {
      final fs = InMemoryFs();
      _seedLibApp(fs, '/proj');
      fs.writeAsString(
        '/proj/.dowel/plugins.json',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'plugins': [
            <String, dynamic>{
              'name': 'b_logger',
              'providerImport': 'package:b_logger/cli.dart',
              'providerClass': 'BLoggerDowelProvider',
              'registeredAt': '2026-05-18T09:00:00.000Z',
            },
            <String, dynamic>{
              'name': 'a_logger',
              'providerImport': 'package:a_logger/cli.dart',
              'providerClass': 'ALoggerDowelProvider',
              'registeredAt': '2026-05-18T09:01:00.000Z',
            },
          ],
        }),
      );

      final cmd = _cmd(fs, '/proj');
      await cmd.handle(_ctx());
      final first = fs.readAsString('/proj/lib/app/_plugins.g.dart');
      await cmd.handle(_ctx());
      final second = fs.readAsString('/proj/lib/app/_plugins.g.dart');

      expect(second, first,
          reason: 'codegen must be deterministic across consecutive runs');
    });

    test('malformed providerClass identifier is rejected', () async {
      final fs = InMemoryFs();
      _seedLibApp(fs, '/proj');
      fs.writeAsString(
        '/proj/.dowel/plugins.json',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'plugins': [
            <String, dynamic>{
              'name': 'evil',
              'providerImport': 'package:evil/cli.dart',
              // Injection attempt: not a valid Dart identifier.
              'providerClass': 'Evil(); main() { print("pwned"); class X',
              'registeredAt': '2026-05-18T09:00:00.000Z',
            },
          ],
        }),
      );

      await expectLater(
        _cmd(fs, '/proj').handle(_ctx()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('providerClass'),
              contains('evil'),
            ),
          ),
        ),
      );
    });

    test('emits success summary mentioning count and output path', () async {
      final fs = InMemoryFs();
      _seedLibApp(fs, '/proj');
      fs.writeAsString(
        '/proj/.dowel/plugins.json',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'plugins': [
            <String, dynamic>{
              'name': 'magic_logger',
              'providerImport': 'package:magic_logger/cli.dart',
              'providerClass': 'MagicLoggerDowelProvider',
              'registeredAt': '2026-05-18T09:00:00.000Z',
            },
          ],
        }),
      );

      final output = BufferedOutput();
      final ctx = DowelContext.bare(
        MapInput(const <String, dynamic>{}),
        output,
      );

      final code = await _cmd(fs, '/proj').handle(ctx);

      expect(code, 0);
      expect(output.content, contains('1'));
      expect(output.content, contains('lib/app/_plugins.g.dart'));
    });

    test(
        'refresh purges .dowel/cli-bundle and .dowel/build.stamp after '
        'regenerating _plugins.g.dart (real-FS path)', () async {
      // Issue #9 GAP A: the cache-purge runs against real-FS (dart:io), not
      // the InMemoryFs seam, because ./bin/dowel probes real disk for the stamp.
      // This test bypasses _cmd(InMemoryFs, ...) and constructs the command
      // against a real-FS tempDir so the assertions are non-vacuous.
      final tempDir = Directory.systemTemp.createTempSync('refresh_purge_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      // 1. Seed lib/app/.keep so the production directoryExists check passes
      //    against real disk (no InMemoryFs probe in this test).
      final libAppDir = Directory(p.join(tempDir.path, 'lib', 'app'))
        ..createSync(recursive: true);
      File(p.join(libAppDir.path, '.keep')).writeAsStringSync('');

      // 2. Seed an empty plugins.json so the refresh generates an empty
      //    _plugins.g.dart and reaches the post-write cache-purge hook.
      final dowelDir = Directory(p.join(tempDir.path, '.dowel'))
        ..createSync(recursive: true);
      File(p.join(dowelDir.path, 'plugins.json')).writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'plugins': <dynamic>[],
        }),
      );

      // 3. Pre-create the cache artefacts the post-refresh hook must purge.
      final cacheDir = Directory(p.join(dowelDir.path, 'cli-bundle'))
        ..createSync(recursive: true);
      File(p.join(cacheDir.path, 'sentinel')).writeAsStringSync('');
      File(p.join(dowelDir.path, 'build.stamp'))
          .writeAsStringSync('deadbeef:3.4.0');

      // 4. Construct against real FS (no fs:, defaults to RealFs; the
      //    directoryExists default probes Directory.existsSync).
      final command = PluginsRefreshCommand(projectRoot: tempDir.path);

      final code = await command.handle(_ctx());
      expect(code, 0);

      // 5. Refresh still regenerated the codegen barrel.
      expect(
        File(p.join(tempDir.path, 'lib', 'app', '_plugins.g.dart'))
            .existsSync(),
        isTrue,
        reason: 'refresh must still produce lib/app/_plugins.g.dart',
      );

      // 6. Both cache artefacts must be gone so the next ./bin/dowel rebuilds.
      expect(
        Directory(p.join(tempDir.path, '.dowel', 'cli-bundle')).existsSync(),
        isFalse,
        reason:
            'refresh must purge .dowel/cli-bundle/ so the next ./bin/dowel rebuilds',
      );
      expect(
        File(p.join(tempDir.path, '.dowel', 'build.stamp')).existsSync(),
        isFalse,
        reason:
            'refresh must purge .dowel/build.stamp so needs_build() trips on next call',
      );
    });
  });

  group('PluginsRefreshCommand output is what dart format writes', () {
    /// Renders the barrel for [entries] (`name` to `providerClass`) through a
    /// real refresh and returns the file.
    Future<String> render(Map<String, String> entries) async {
      final fs = InMemoryFs();
      _seedLibApp(fs, '/proj');
      fs.writeAsString(
        '/proj/.dowel/plugins.json',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'plugins': <Map<String, String>>[
            for (final MapEntry(:key, :value) in entries.entries)
              <String, String>{
                'name': key,
                'providerImport': 'package:$key/cli.dart',
                'providerClass': value,
                'registeredAt': '2026-05-18T09:00:00.000Z',
              },
          ],
        }),
      );
      await _cmd(fs, '/proj').handle(_ctx());

      return fs.readAsString('/proj/lib/app/_plugins.g.dart');
    }

    const header = '// GENERATED: do not edit by hand.\n'
        '// Regenerate via: dart run dowel plugins:refresh\n'
        '//\n'
        '// Source: .dowel/plugins.json\n'
        '\n'
        "import 'package:dowel/dowel.dart';\n";

    test('no plugins: an empty list and no trailing blank line', () async {
      expect(
        await render(const <String, String>{}),
        '$header\n'
        'List<DowelServiceProvider> autoDiscoveredProviders() {\n'
        '  return <DowelServiceProvider>[];\n'
        '}\n',
      );
    });

    test('a list that fits on one line stays on one line', () async {
      expect(
        await render(const <String, String>{'tapir': 'TapirDowelProvider'}),
        "${header}import 'package:tapir/cli.dart' show TapirDowelProvider;\n"
        '\n'
        'List<DowelServiceProvider> autoDiscoveredProviders() {\n'
        '  return <DowelServiceProvider>[TapirDowelProvider()];\n'
        '}\n',
      );
    });

    test('a list longer than 80 columns splits one entry per line', () async {
      final generated = await render(const <String, String>{
        'crumbs': 'CrumbsDowelProvider',
        'tapir': 'TapirDowelProvider',
        'magic_notifications': 'MagicNotificationsDowelProvider',
      });

      expect(
        generated,
        endsWith(
          '  return <DowelServiceProvider>[\n'
          '    CrumbsDowelProvider(),\n'
          '    MagicNotificationsDowelProvider(),\n'
          '    TapirDowelProvider(),\n'
          '  ];\n'
          '}\n',
        ),
      );
      // An import past 80 columns breaks before `show`, as the formatter does.
      expect(
        generated,
        contains(
          "import 'package:magic_notifications/cli.dart'\n"
          '    show MagicNotificationsDowelProvider;\n',
        ),
      );
    });
  });
}

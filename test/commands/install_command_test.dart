import 'dart:convert';
import 'dart:io';

// Public barrel: must surface InstallDowelCommand. This is the import path the
// magic package (and any third-party plugin) uses to delegate to dowel's
// install. If the export line in lib/dowel.dart is dropped, the
// `InstallDowelCommand()` references below fail to compile, catching the
// regression at the barrel-export boundary.
import 'package:dowel/dowel.dart';
// Private import: only used for the test seam (resetting processRunner on
// MakeFastCliCommand). InstallDowelCommand itself MUST be reachable via the
// public barrel above.
import 'package:dowel/src/commands/make_fast_cli_command.dart';
import 'package:dowel/src/console/dowel_version.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Records every [Process.run]-style invocation and returns scripted results.
///
/// `InstallDowelCommand.scaffoldInto` does no process work itself; it auto-chains
/// `MakeFastCliCommand.scaffoldInto` at the end of its 6 phases. That chained
/// scaffold runs `chmod`, `dart --version`, `dart build cli`. Recording those
/// calls is the test seam for verifying the auto-chain fired without spinning
/// up real child processes.
///
/// Test-only private type per `.claude/rules/tests.md` (`_RecordingRunner`
/// prefix; copy-paste from `make_fast_cli_command_test.dart:16-30` preferred
/// over extraction until the third caller emerges).
class _RecordingRunner {
  _RecordingRunner(this.scripted);

  final Map<String, ProcessResult> scripted;
  final List<List<String>> calls = [];

  Future<ProcessResult> call(
    String exe,
    List<String> args, {
    String? workingDirectory,
  }) async {
    calls.add([exe, ...args]);
    return scripted['$exe ${args.join(' ')}'] ?? ProcessResult(0, 0, '', '');
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Seeds [root] with the minimum pubspec.yaml + pubspec.lock needed for the
/// install pipeline to run end-to-end (scaffold + auto-chained make:fast-cli).
String _seedPubspec(String root, {required String name}) {
  final pubspec = '''
name: $name
description: A test project.

environment:
  sdk: ^3.4.0

dependencies:
  flutter:
    sdk: flutter
''';
  final path = p.join(root, 'pubspec.yaml');
  File(path).writeAsStringSync(pubspec);

  // pubspec.lock is required by make:fast-cli's stamp computation; an empty
  // lock is fine because the SHA256 is computed over the bytes.
  File(p.join(root, 'pubspec.lock')).writeAsStringSync('packages: {}\n');
  return path;
}

/// Builds the scripted [ProcessResult] map for the happy path: chmod succeeds,
/// dart --version returns a parseable semver, dart build cli succeeds. Mirrors
/// `make_fast_cli_command_test.dart:94-100`.
Map<String, ProcessResult> _happyScripted(String root) => {
      'chmod +x ${p.join(root, 'bin', 'dowel')}': ProcessResult(0, 0, '', ''),
      'dart --version':
          ProcessResult(0, 0, '', 'Dart SDK version: 3.8.0 (stable) ...'),
      'dart build cli -t bin/dispatcher.dart -o .dowel/cli-bundle':
          ProcessResult(0, 0, 'Build complete.', ''),
    };

/// Builds an [DowelContext] backed by a [BufferedOutput].
DowelContext _ctx() {
  return DowelContext.bare(
    MapInput(const <String, dynamic>{}),
    BufferedOutput(),
  );
}

void main() {
  group('InstallDowelCommand metadata', () {
    final cmd = InstallDowelCommand();

    test('name is install', () {
      expect(cmd.name, 'install');
    });

    test('boot is CommandBoot.none', () {
      expect(cmd.boot, CommandBoot.none);
    });

    test('description mentions canonical scaffold + fast-CLI', () {
      expect(cmd.description, contains('bin/dispatcher.dart'));
      expect(cmd.description, contains('bin/dowel'));
    });
  });

  group('InstallDowelCommand.scaffoldInto', () {
    late Directory tempRoot;
    late _RecordingRunner runner;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('install_cmd_');
      _seedPubspec(tempRoot.path, name: 'example');
      runner = _RecordingRunner(_happyScripted(tempRoot.path));
      MakeFastCliCommand.processRunner = runner.call;
    });

    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      MakeFastCliCommand.processRunner = Process.run;
    });

    test('writes bin/dispatcher.dart with consumer name substituted', () async {
      final result = await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );
      expect(result, 0);

      final dispatcherPath = p.join(tempRoot.path, 'bin', 'dispatcher.dart');
      expect(File(dispatcherPath).existsSync(), isTrue);

      final content = File(dispatcherPath).readAsStringSync();
      // The {{ name }} placeholder must be substituted with the consumer name
      // from pubspec.yaml; raw template tokens must NOT leak through.
      expect(content.contains("package:example/app/commands/_index.g.dart"),
          isTrue);
      expect(content.contains("package:example/app/_plugins.g.dart"), isTrue);
      expect(content.contains('{{ name }}'), isFalse);
      // The rendered dispatcher must forward collectMcpTools so plugin
      // providers' tool descriptors surface in tools/list responses (issue #7,
      // Bug A). Without this arg, runDowel's split-API never calls
      // registerMcpToolsFor and the MCP server returns an empty tools array.
      expect(content, contains('collectMcpTools'));
    });

    test('writes lib/app/_plugins.g.dart initial barrel', () async {
      await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );

      final pluginsGPath =
          p.join(tempRoot.path, 'lib', 'app', '_plugins.g.dart');
      expect(File(pluginsGPath).existsSync(), isTrue);

      final content = File(pluginsGPath).readAsStringSync();
      expect(content, contains('autoDiscoveredProviders'));
    });

    test('writes lib/app/commands/_index.g.dart initial barrel', () async {
      await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );

      final indexPath =
          p.join(tempRoot.path, 'lib', 'app', 'commands', '_index.g.dart');
      expect(File(indexPath).existsSync(), isTrue);

      final content = File(indexPath).readAsStringSync();
      expect(content, contains('List<DowelCommand>'));
    });

    test('injects dowel with a caret on the running version', () async {
      // No .dart_tool/package_config.json seeded → path-dep branch returns
      // null, so the version-constraint branch fires.
      await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );

      final pubspecContent =
          File(p.join(tempRoot.path, 'pubspec.yaml')).readAsStringSync();
      expect(pubspecContent, contains('dowel: ^$dowelVersion'));
      expect(pubspecContent, isNot(contains('dowel: any')));
    });

    test('keeps the dowel constraint the project already declares', () async {
      // `dart pub add dowel` wrote a caret before `install` ran.
      final pubspec = File(p.join(tempRoot.path, 'pubspec.yaml'));
      pubspec.writeAsStringSync(
        '${pubspec.readAsStringSync()}  dowel: ^0.0.9\n',
      );

      await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );

      final content = pubspec.readAsStringSync();
      expect(content, contains('dowel: ^0.0.9'));
      expect(RegExp(r'^\s+dowel:', multiLine: true).allMatches(content),
          hasLength(1));
    });

    test('decodes a percent-encoded rootUri with a trailing slash', () async {
      // pub writes a relative rootUri percent-encoded; joined as a plain path
      // it named a directory that does not exist.
      Directory(p.join(tempRoot.path, '.dart_tool')).createSync();
      File(p.join(tempRoot.path, '.dart_tool', 'package_config.json'))
          .writeAsStringSync(jsonEncode(<String, dynamic>{
        'configVersion': 2,
        'packages': <Map<String, String>>[
          <String, String>{
            'name': 'dowel',
            'rootUri': '../../plug%20%C4%B1/',
            'packageUri': 'lib/',
          },
        ],
      }));

      await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );

      final content =
          File(p.join(tempRoot.path, 'pubspec.yaml')).readAsStringSync();
      expect(content, contains('path: ../plug ı'));
    });

    test('stops on a dispatcher fluttersdk_artisan generated', () async {
      final dispatcher = File(p.join(tempRoot.path, 'bin', 'dispatcher.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          "import 'package:fluttersdk_artisan/artisan.dart';\n\n"
          'Future<void> main(List<String> args) async {\n'
          '  exitCode = await runArtisan(args);\n'
          '}\n',
        );
      final ctx = _ctx();

      final result = await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: ctx,
      );

      expect(result, 1);
      expect(dispatcher.readAsStringSync(), contains('fluttersdk_artisan'));
      final out = (ctx.output as BufferedOutput).content;
      expect(out, contains('bin/dispatcher.dart'));
      expect(out, contains('dart pub remove fluttersdk_artisan'));
      expect(out, contains('dart run dowel install'));
      expect(out, contains('dart run dowel commands:refresh'));
      expect(runner.calls, isEmpty, reason: 'nothing may build on it');
    });

    test(
      'injects dowel as path dep when package_config.json '
      'resolves it locally',
      () async {
        // Seed .dart_tool/package_config.json so the path resolver finds
        // dowel at a known relative location.
        final configDir = Directory(p.join(tempRoot.path, '.dart_tool'));
        configDir.createSync(recursive: true);
        File(p.join(configDir.path, 'package_config.json')).writeAsStringSync(
          '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "dowel",
      "rootUri": "../../../dowel",
      "packageUri": "lib/",
      "languageVersion": "3.4"
    }
  ]
}
''',
        );

        await InstallDowelCommand.scaffoldInto(
          root: tempRoot.path,
          force: false,
          ctx: _ctx(),
        );

        final pubspecContent =
            File(p.join(tempRoot.path, 'pubspec.yaml')).readAsStringSync();
        // rootUri `../../../dowel` is relative to `.dart_tool/`;
        // rebased onto the consumer root it becomes `../../dowel`.
        expect(
          pubspecContent.contains('path: ../../dowel'),
          isTrue,
          reason: 'expected path-dep form when package_config resolves locally',
        );
        // Guard the regression: must NOT also emit `any`.
        expect(
          RegExp(r'dowel:\s*any', multiLine: true).hasMatch(pubspecContent),
          isFalse,
        );
      },
    );

    test('returns 1 when pubspec.yaml has no name field', () async {
      File(p.join(tempRoot.path, 'pubspec.yaml')).writeAsStringSync(
        'description: Nameless project.\n',
      );

      final result = await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );
      expect(result, 1);
    });

    test('skips file writes when files exist and force=false (idempotent)',
        () async {
      // First run lands the three files.
      await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );

      // Stamp bin/dispatcher.dart so we can detect a re-write.
      final dispatcherPath = p.join(tempRoot.path, 'bin', 'dispatcher.dart');
      const sentinel = '// SENTINEL: must be preserved\n';
      File(dispatcherPath).writeAsStringSync(
        sentinel + File(dispatcherPath).readAsStringSync(),
      );

      // Second run with force=false; reset runner because the first scaffold
      // also fired the auto-chain.
      final runner2 = _RecordingRunner(_happyScripted(tempRoot.path));
      MakeFastCliCommand.processRunner = runner2.call;

      await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );

      expect(
        File(dispatcherPath).readAsStringSync().startsWith(sentinel),
        isTrue,
      );
    });

    test('force=true overwrites bin/dispatcher.dart', () async {
      await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );

      final dispatcherPath = p.join(tempRoot.path, 'bin', 'dispatcher.dart');
      const sentinel = '// SENTINEL: must be overwritten\n';
      File(dispatcherPath).writeAsStringSync(
        sentinel + File(dispatcherPath).readAsStringSync(),
      );

      // Second runner because force=true triggers chmod + build re-runs.
      final runner2 = _RecordingRunner(_happyScripted(tempRoot.path));
      MakeFastCliCommand.processRunner = runner2.call;

      await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: true,
        ctx: _ctx(),
      );

      expect(
        File(dispatcherPath).readAsStringSync().startsWith(sentinel),
        isFalse,
      );
    });

    test('auto-chains make:fast-cli (dart build cli is invoked)', () async {
      await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );

      // The auto-chain at phase 6 calls MakeFastCliCommand.scaffoldInto which
      // invokes `dart build cli -t bin/dispatcher.dart -o .dowel/cli-bundle`.
      // Recording that exact invocation proves the chain fired.
      expect(
        runner.calls,
        anyElement(
          equals([
            'dart',
            'build',
            'cli',
            '-t',
            'bin/dispatcher.dart',
            '-o',
            '.dowel/cli-bundle',
          ]),
        ),
        reason: 'install must auto-chain make:fast-cli at the final phase',
      );

      // And bin/dowel must be on disk as a downstream effect of the auto-chain.
      expect(
        File(p.join(tempRoot.path, 'bin', 'dowel')).existsSync(),
        isTrue,
      );
    });

    test('returns 0 on success', () async {
      final result = await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );
      expect(result, 0);
    });

    test(
      're-running install on a populated .dowel/plugins.json regenerates '
      'the canonical _plugins.g.dart barrel (does not stomp with empty stub)',
      () async {
        // 1. First install: lands the canonical scaffold + initial empty barrel.
        await InstallDowelCommand.scaffoldInto(
          root: tempRoot.path,
          force: false,
          ctx: _ctx(),
        );

        // 2. Seed an existing plugins.json with two registered plugins, as if
        //    `plugin:install` had previously enrolled them. This mirrors the
        //    real-world state where a consumer has running plugins, then
        //    re-runs `install` (e.g. to refresh the dispatcher template).
        final pluginsJsonPath = p.join(tempRoot.path, '.dowel', 'plugins.json');
        Directory(p.dirname(pluginsJsonPath)).createSync(recursive: true);
        File(pluginsJsonPath).writeAsStringSync('''
{
  "version": 1,
  "plugins": [
    {
      "name": "magic_logger",
      "providerImport": "package:magic_logger/cli.dart",
      "providerClass": "MagicLoggerDowelProvider",
      "registeredAt": "2026-05-19T10:00:00.000Z"
    },
    {
      "name": "tapir",
      "providerImport": "package:tapir/cli.dart",
      "providerClass": "TapirDowelProvider",
      "registeredAt": "2026-05-19T10:00:00.000Z"
    }
  ]
}
''');

        // 3. Re-run install with --force so the barrel write is attempted (the
        //    pre-fix bug stomped the canonical barrel with the empty stub).
        final runner2 = _RecordingRunner(_happyScripted(tempRoot.path));
        MakeFastCliCommand.processRunner = runner2.call;

        await InstallDowelCommand.scaffoldInto(
          root: tempRoot.path,
          force: true,
          ctx: _ctx(),
        );

        // 4. Assert the canonical barrel reflects plugins.json (both provider
        //    constructors present), NOT the empty initial stub.
        final pluginsGPath =
            p.join(tempRoot.path, 'lib', 'app', '_plugins.g.dart');
        final content = File(pluginsGPath).readAsStringSync();

        expect(
          content,
          contains('MagicLoggerDowelProvider()'),
          reason: 'install must re-run plugins:refresh to preserve the '
              'canonical state when plugins.json has entries',
        );
        expect(content, contains('TapirDowelProvider()'));
        expect(content, contains("package:magic_logger/cli.dart"));
        expect(content, contains("package:tapir/cli.dart"));
        // Negative: the empty-stub form must NOT remain.
        expect(
          content.contains('return <DowelServiceProvider>[];'),
          isFalse,
          reason: 'install stomped the canonical barrel with the empty stub',
        );
      },
    );

    test(
      'fresh install without .dowel/plugins.json keeps the empty initial '
      'barrel (no plugins:refresh side effect)',
      () async {
        // No plugins.json seeded → empty initial stub stays in place.
        await InstallDowelCommand.scaffoldInto(
          root: tempRoot.path,
          force: false,
          ctx: _ctx(),
        );

        final pluginsGPath =
            p.join(tempRoot.path, 'lib', 'app', '_plugins.g.dart');
        final content = File(pluginsGPath).readAsStringSync();

        expect(content, contains('autoDiscoveredProviders'));
        // No plugins.json => no entries to render; the file remains the
        // initial empty stub shape.
        expect(content.contains('DowelProvider()'), isFalse);
      },
    );

    test(
      'pubspec dep injection is idempotent (exactly one dowel '
      'entry after two scaffold runs)',
      () async {
        await InstallDowelCommand.scaffoldInto(
          root: tempRoot.path,
          force: false,
          ctx: _ctx(),
        );

        final runner2 = _RecordingRunner(_happyScripted(tempRoot.path));
        MakeFastCliCommand.processRunner = runner2.call;

        await InstallDowelCommand.scaffoldInto(
          root: tempRoot.path,
          force: false,
          ctx: _ctx(),
        );

        final pubspecContent =
            File(p.join(tempRoot.path, 'pubspec.yaml')).readAsStringSync();
        expect(
          RegExp(r'^\s*dowel:', multiLine: true)
              .allMatches(pubspecContent)
              .length,
          1,
        );
      },
    );

    test('propagates non-zero exit from make:fast-cli when build fails',
        () async {
      // Override the build script to fail. The auto-chain's non-zero exit
      // must bubble back through InstallDowelCommand.scaffoldInto.
      final failing = _RecordingRunner({
        'chmod +x ${p.join(tempRoot.path, 'bin', 'dowel')}':
            ProcessResult(0, 0, '', ''),
        'dart --version':
            ProcessResult(0, 0, '', 'Dart SDK version: 3.8.0 (stable) ...'),
        'dart build cli -t bin/dispatcher.dart -o .dowel/cli-bundle':
            ProcessResult(0, 1, '', 'compile error'),
      });
      MakeFastCliCommand.processRunner = failing.call;

      final result = await InstallDowelCommand.scaffoldInto(
        root: tempRoot.path,
        force: false,
        ctx: _ctx(),
      );

      expect(result, 1,
          reason: 'make:fast-cli build failure must propagate as exit 1');
    });
  });

  group('InstallDowelCommand barrel export', () {
    test(
        'InstallDowelCommand is exported from public barrel '
        '(package:dowel/dowel.dart)', () {
      // Symbol existence check: this test file imports InstallDowelCommand only
      // via the public barrel at the top (NO direct import from
      // `lib/src/commands/install_command.dart`). If the export line at
      // lib/dowel.dart is dropped, this construction fails to compile,
      // catching the regression at the barrel-export boundary.
      final cmd = InstallDowelCommand();
      expect(cmd.name, 'install');
    });
  });
}

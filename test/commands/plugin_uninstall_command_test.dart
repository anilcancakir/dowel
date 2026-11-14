import 'dart:convert';
import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:dowel/src/commands/plugin_uninstall_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

/// Builds a fake consumer project tree under [root] with the files
/// `plugin:uninstall` needs: pubspec.yaml, package_config.json, a published
/// config file, and the install record at `.dowel/installed/<plugin>.json`.
///
/// @param root         Temp project root.
/// @param pluginName   Plugin pubspec package name.
/// @param ops          Optional list of recorded ops to embed in the install
///                     record. Defaults to a single WriteFile so the reverse
///                     transaction has something concrete to undo.
void _seedInstalledProject(
  Directory root, {
  required String pluginName,
  List<Map<String, dynamic>>? ops,
}) {
  // 1. pubspec.yaml.
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(
    'name: consumer\n'
    'dependencies:\n'
    '  $pluginName: ^1.0.0\n',
  );

  // 2. .dart_tool/package_config.json.
  final pkgConfigDir = Directory(p.join(root.path, '.dart_tool'))
    ..createSync(recursive: true);
  File(p.join(pkgConfigDir.path, 'package_config.json'))
      .writeAsStringSync('{"packages":[{"name": "$pluginName"}]}\n');

  // 3. Published config file (the WriteFile op in the record points here).
  final configPath = p.join(root.path, 'lib', 'config', 'demo.dart');
  Directory(p.dirname(configPath)).createSync(recursive: true);
  File(configPath).writeAsStringSync('const x = 1;\n');

  // 4. Install record.
  final recordDir = Directory(p.join(root.path, '.dowel', 'installed'))
    ..createSync(recursive: true);
  File(p.join(recordDir.path, '$pluginName.json')).writeAsStringSync(
    jsonEncode(<String, dynamic>{
      'version': 1,
      'plugin': pluginName,
      'installedAt': '2025-01-01T00:00:00.000Z',
      'ops':
          ops ??
          <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'WriteFile',
              'targetPath': configPath,
              'content': 'const x = 1;\n',
            },
          ],
      'stubHashes': <String, String>{},
    }),
  );
}

/// Writes an `install.yaml` manifest at [path] declaring [pluginName].
void _writeInstallYaml(String path, String pluginName) {
  File(path).writeAsStringSync('plugin_name: $pluginName\n');
}

/// Builds an [DowelContext] backed by a [MapInput] + [BufferedOutput].
DowelContext _ctxWith(
  Map<String, dynamic> options, {
  List<String> positional = const [],
  CommandSignature? signature,
}) {
  return DowelContext.bare(
    MapInput(options, positional: positional, signature: signature),
    BufferedOutput(),
  );
}

/// Test subclass injecting deterministic paths so the command never touches
/// the host package's filesystem layout.
class _TestablePluginUninstallCommand extends PluginUninstallCommand {
  _TestablePluginUninstallCommand({
    required this.fakeProjectRoot,
    required this.fakeInstallYamlPath,
    this.confirmAnswer = true,
  });

  /// Pinned project root for the test invocation.
  final String fakeProjectRoot;

  /// install.yaml path the resolver returns (the manifest still exists at
  /// uninstall time so the command can re-parse it).
  final String fakeInstallYamlPath;

  /// Forced confirm() answer for tests that exercise the interactive prompt.
  final bool confirmAnswer;

  @override
  String getProjectRoot() => fakeProjectRoot;

  @override
  Future<String?> resolveInstallYaml(String pluginName) async =>
      fakeInstallYamlPath;

  @override
  bool promptConfirmation(DowelContext ctx, String pluginName) => confirmAnswer;
}

/// Builds the standard option map for an uninstall invocation. Tests pass
/// partial overrides via the [overrides] map.
Map<String, dynamic> _baseOpts({Map<String, dynamic>? overrides}) {
  final base = <String, dynamic>{
    'force': false,
    'dry-run': false,
    'non-interactive': false,
    'no-bootstrap': false,
  };
  if (overrides != null) base.addAll(overrides);
  return base;
}

/// True when a write into a read-only (`chmod 555`) directory still succeeds,
/// as it does for root or a process with `CAP_DAC_OVERRIDE`. The read-only
/// registry test needs a runner that honours directory permissions.
bool _bypassesDirectoryPermissions() {
  final probe = Directory.systemTemp.createTempSync('plun_perm_probe_');
  try {
    Process.runSync('chmod', <String>['555', probe.path]);
    final file = File(p.join(probe.path, 'probe'));
    try {
      file.writeAsStringSync('x');
      return true;
    } on FileSystemException {
      return false;
    }
  } finally {
    Process.runSync('chmod', <String>['755', probe.path]);
    probe.deleteSync(recursive: true);
  }
}

void main() {
  group('PluginUninstallCommand — signature DSL', () {
    test('inherits the 4 base flags via DowelInstallCommand.baseFlags', () {
      final cmd = PluginUninstallCommand();
      final parsed = cmd.parsedSignature!;
      final optionNames = parsed.options.map((o) => o.name).toSet();

      expect(
        optionNames,
        containsAll(<String>[
          'force',
          'dry-run',
          'non-interactive',
          'no-bootstrap',
        ]),
      );
    });

    test('declares only the {name} positional on top of the base flags', () {
      final cmd = PluginUninstallCommand();
      final parsed = cmd.parsedSignature!;

      expect(parsed.name, 'plugin:uninstall');
      expect(parsed.arguments.map((a) => a.name), contains('name'));
      expect(
        parsed.options.length,
        4,
        reason: 'No plugin-specific flags beyond the base 4.',
      );
    });

    test('extends DowelInstallCommand (CommandBoot.none)', () {
      final cmd = PluginUninstallCommand();
      expect(cmd, isA<DowelInstallCommand>());
      expect(cmd.boot, CommandBoot.none);
    });

    test('pluginName(ctx) derives from the positional name argument', () {
      final cmd = PluginUninstallCommand();
      final ctx = _ctxWith(
        const <String, dynamic>{},
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );
      expect(cmd.pluginName(ctx), 'magic_logger');
    });
  });

  group('PluginUninstallCommand — happy path', () {
    test('full uninstall removes the published file and the record', () async {
      final root = Directory.systemTemp.createTempSync('plun_full_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedInstalledProject(root, pluginName: 'demo_plugin');
      final manifestPath = p.join(root.path, 'demo_install.yaml');
      _writeInstallYaml(manifestPath, 'demo_plugin');

      final cmd = _TestablePluginUninstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final ctx = _ctxWith(
        _baseOpts(overrides: const {'force': true}),
        positional: const ['demo_plugin'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      // Published file reversed by the WriteFile → DeleteFile mapping.
      expect(
        File(p.join(root.path, 'lib', 'config', 'demo.dart')).existsSync(),
        isFalse,
      );

      // Install record deleted on Success.
      expect(
        File(p.join(root.path, '.dowel', 'installed', 'demo_plugin.json'))
            .existsSync(),
        isFalse,
      );
    });

    test(
      'uninstall drops the plugin from plugins.json and the barrel',
      () async {
        final root = Directory.systemTemp.createTempSync('plun_registry_');
        addTearDown(() => root.deleteSync(recursive: true));
        _seedInstalledProject(root, pluginName: 'demo_plugin');
        final manifestPath = p.join(root.path, 'demo_install.yaml');
        _writeInstallYaml(manifestPath, 'demo_plugin');

        // The install left the plugin registered and the barrel generated.
        Directory(p.join(root.path, 'lib', 'app')).createSync(recursive: true);
        File(p.join(root.path, '.dowel', 'plugins.json')).writeAsStringSync(
          jsonEncode(<String, dynamic>{
            'version': 1,
            'plugins': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'demo_plugin',
                'providerImport': 'package:demo_plugin/cli.dart',
                'providerClass': 'DemoPluginDowelProvider',
                'registeredAt': '2025-01-01T00:00:00.000Z',
              },
              <String, dynamic>{
                'name': 'other_plugin',
                'providerImport': 'package:other_plugin/cli.dart',
                'providerClass': 'OtherPluginDowelProvider',
                'registeredAt': '2025-01-01T00:00:00.000Z',
              },
            ],
          }),
        );

        final cmd = _TestablePluginUninstallCommand(
          fakeProjectRoot: root.path,
          fakeInstallYamlPath: manifestPath,
        );
        final ctx = _ctxWith(
          _baseOpts(overrides: const {'force': true}),
          positional: const ['demo_plugin'],
          signature: cmd.parsedSignature,
        );

        final exit = await cmd.handle(ctx);
        expect(exit, 0);

        final registry = jsonDecode(
          File(p.join(root.path, '.dowel', 'plugins.json')).readAsStringSync(),
        ) as Map<String, dynamic>;
        final names = (registry['plugins'] as List<dynamic>)
            .map((dynamic e) => (e as Map<String, dynamic>)['name'])
            .toList();
        expect(names, equals(<String>['other_plugin']));

        final barrel = File(p.join(root.path, 'lib', 'app', '_plugins.g.dart'))
            .readAsStringSync();
        expect(barrel, isNot(contains('DemoPluginDowelProvider')));
        expect(barrel, contains('OtherPluginDowelProvider'));
      },
    );

    test(
      'uninstall asks the operator to drop the registry entry by hand when '
      'the registry cannot be written',
      () async {
        final root = Directory.systemTemp.createTempSync('plun_registry_ro_');
        addTearDown(() => root.deleteSync(recursive: true));
        _seedInstalledProject(root, pluginName: 'demo_plugin');
        final manifestPath = p.join(root.path, 'demo_install.yaml');
        _writeInstallYaml(manifestPath, 'demo_plugin');

        Directory(p.join(root.path, 'lib', 'app')).createSync(recursive: true);
        File(p.join(root.path, '.dowel', 'plugins.json')).writeAsStringSync(
          jsonEncode(<String, dynamic>{
            'version': 1,
            'plugins': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'demo_plugin',
                'providerImport': 'package:demo_plugin/cli.dart',
                'providerClass': 'DemoPluginDowelProvider',
                'registeredAt': '2025-01-01T00:00:00.000Z',
              },
            ],
          }),
        );

        // A read-only .dowel/ lets the registry's temp file fail to appear,
        // while the install record under .dowel/installed/ stays removable.
        final dowelDir = p.join(root.path, '.dowel');
        Process.runSync('chmod', <String>['555', dowelDir]);
        addTearDown(() => Process.runSync('chmod', <String>['755', dowelDir]));

        final cmd = _TestablePluginUninstallCommand(
          fakeProjectRoot: root.path,
          fakeInstallYamlPath: manifestPath,
        );
        final ctx = _ctxWith(
          _baseOpts(overrides: const {'force': true}),
          positional: const ['demo_plugin'],
          signature: cmd.parsedSignature,
        );

        final exit = await cmd.handle(ctx);

        expect(exit, 0);
        expect(
          (ctx.output as BufferedOutput).content,
          contains('Remove the "demo_plugin" entry from .dowel/plugins.json'),
        );
      },
      skip: Platform.isWindows
          ? 'chmod semantics'
          : _bypassesDirectoryPermissions()
          ? 'runner bypasses directory permissions (root)'
          : false,
    );

    test('uninstall purges .dowel/cli-bundle and .dowel/build.stamp '
        'after successful removal', () async {
      // Issue #9 GAP A: after `plugin:uninstall` reverses the install, the AOT
      // cache must be invalidated so the next `./bin/dowel` rebuilds without
      // the removed plugin's command surface.
      final root = Directory.systemTemp.createTempSync('plun_cachepurge_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedInstalledProject(root, pluginName: 'demo_plugin');
      final manifestPath = p.join(root.path, 'demo_install.yaml');
      _writeInstallYaml(manifestPath, 'demo_plugin');

      // 1. Pre-create the cache artefacts that the post-uninstall hook must purge.
      final cacheDir = Directory(p.join(root.path, '.dowel', 'cli-bundle'))
        ..createSync(recursive: true);
      File(p.join(cacheDir.path, 'sentinel')).writeAsStringSync('');
      File(p.join(root.path, '.dowel', 'build.stamp'))
          .writeAsStringSync('deadbeef:3.4.0');

      final cmd = _TestablePluginUninstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final ctx = _ctxWith(
        _baseOpts(overrides: const {'force': true}),
        positional: const ['demo_plugin'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      // 2. Both cache artefacts must be gone after a successful uninstall.
      expect(
        Directory(p.join(root.path, '.dowel', 'cli-bundle')).existsSync(),
        isFalse,
        reason: 'uninstall must purge .dowel/cli-bundle/ so the next ./bin/dowel rebuilds',
      );
      expect(
        File(p.join(root.path, '.dowel', 'build.stamp')).existsSync(),
        isFalse,
        reason: 'uninstall must purge .dowel/build.stamp so needs_build() trips on next call',
      );
    });

    test('--force skips the interactive confirm prompt', () async {
      final root = Directory.systemTemp.createTempSync('plun_force_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedInstalledProject(root, pluginName: 'demo_plugin');
      final manifestPath = p.join(root.path, 'demo_install.yaml');
      _writeInstallYaml(manifestPath, 'demo_plugin');

      // Confirm answer is set to FALSE — if --force is honoured the command
      // must skip the prompt entirely and proceed regardless.
      final cmd = _TestablePluginUninstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
        confirmAnswer: false,
      );
      final ctx = _ctxWith(
        _baseOpts(overrides: const {'force': true}),
        positional: const ['demo_plugin'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);
      expect(
        File(p.join(root.path, '.dowel', 'installed', 'demo_plugin.json'))
            .existsSync(),
        isFalse,
      );
    });

    test('--non-interactive skips the confirm prompt', () async {
      final root = Directory.systemTemp.createTempSync('plun_nonint_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedInstalledProject(root, pluginName: 'demo_plugin');
      final manifestPath = p.join(root.path, 'demo_install.yaml');
      _writeInstallYaml(manifestPath, 'demo_plugin');

      final cmd = _TestablePluginUninstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
        confirmAnswer: false,
      );
      final ctx = _ctxWith(
        _baseOpts(overrides: const {'non-interactive': true}),
        positional: const ['demo_plugin'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);
    });

    test('interactive decline returns 0 without modifying state', () async {
      final root = Directory.systemTemp.createTempSync('plun_decline_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedInstalledProject(root, pluginName: 'demo_plugin');
      final manifestPath = p.join(root.path, 'demo_install.yaml');
      _writeInstallYaml(manifestPath, 'demo_plugin');

      // Neither --force nor --non-interactive → prompt runs; confirmAnswer
      // says NO → command must abort without mutating anything.
      final cmd = _TestablePluginUninstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
        confirmAnswer: false,
      );
      final ctx = _ctxWith(
        _baseOpts(),
        positional: const ['demo_plugin'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      // State preserved.
      expect(
        File(p.join(root.path, '.dowel', 'installed', 'demo_plugin.json'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(p.join(root.path, 'lib', 'config', 'demo.dart')).existsSync(),
        isTrue,
      );
    });
  });

  group('PluginUninstallCommand — dry-run', () {
    test(
      '--dry-run reports the planned reverse without touching disk',
      () async {
        final root = Directory.systemTemp.createTempSync('plun_dryrun_');
        addTearDown(() => root.deleteSync(recursive: true));
        _seedInstalledProject(root, pluginName: 'demo_plugin');
        final manifestPath = p.join(root.path, 'demo_install.yaml');
        _writeInstallYaml(manifestPath, 'demo_plugin');

        final cmd = _TestablePluginUninstallCommand(
          fakeProjectRoot: root.path,
          fakeInstallYamlPath: manifestPath,
        );
        final ctx = _ctxWith(
          _baseOpts(overrides: const {'dry-run': true, 'force': true}),
          positional: const ['demo_plugin'],
          signature: cmd.parsedSignature,
        );

        final exit = await cmd.handle(ctx);
        expect(exit, 0);

        // Nothing actually mutated.
        expect(
          File(p.join(root.path, '.dowel', 'installed', 'demo_plugin.json'))
              .existsSync(),
          isTrue,
          reason: 'Dry-run must NOT delete the record.',
        );
        expect(
          File(p.join(root.path, 'lib', 'config', 'demo.dart')).existsSync(),
          isTrue,
          reason: 'Dry-run must NOT delete published files.',
        );

        final out = (ctx.output as BufferedOutput).content;
        expect(
          out.toLowerCase(),
          contains('dry'),
          reason: 'Operator must see a dry-run banner.',
        );
      },
    );
  });

  group('PluginUninstallCommand — failure modes', () {
    test(
      'missing record file errors with a helpful message + exit 1',
      () async {
        final root = Directory.systemTemp.createTempSync('plun_missing_');
        addTearDown(() => root.deleteSync(recursive: true));
        // Seed everything EXCEPT the install record.
        File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: c\n');
        final manifestPath = p.join(root.path, 'demo_install.yaml');
        _writeInstallYaml(manifestPath, 'demo_plugin');

        final cmd = _TestablePluginUninstallCommand(
          fakeProjectRoot: root.path,
          fakeInstallYamlPath: manifestPath,
        );
        final ctx = _ctxWith(
          _baseOpts(overrides: const {'force': true}),
          positional: const ['demo_plugin'],
          signature: cmd.parsedSignature,
        );

        final exit = await cmd.handle(ctx);
        expect(exit, 1);

        final out = (ctx.output as BufferedOutput).content;
        expect(out, contains('[ERROR]'));
        expect(out.toLowerCase(), contains('not installed'));
      },
    );

    test(
      'missing install.yaml errors with a helpful message + exit 1',
      () async {
        final root = Directory.systemTemp.createTempSync('plun_noyaml_');
        addTearDown(() => root.deleteSync(recursive: true));
        _seedInstalledProject(root, pluginName: 'demo_plugin');

        // Subclass returns null for the install.yaml lookup.
        final cmd = _TestablePluginUninstallCommandNoYaml(
          fakeProjectRoot: root.path,
        );
        final ctx = _ctxWith(
          _baseOpts(overrides: const {'force': true}),
          positional: const ['demo_plugin'],
          signature: cmd.parsedSignature,
        );

        final exit = await cmd.handle(ctx);
        expect(exit, 1);
        final out = (ctx.output as BufferedOutput).content;
        expect(out, contains('[ERROR]'));
        expect(out, contains('install.yaml'));
      },
    );

    test('missing plugin name argument errors with exit 1', () async {
      final cmd = PluginUninstallCommand();
      final ctx = _ctxWith(
        _baseOpts(),
        positional: const [],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 1);
      final out = (ctx.output as BufferedOutput).content;
      expect(out, contains('[ERROR]'));
      expect(out, contains('Missing required argument'));
    });

    test(
      'a record an older dowel wrote is refused, dry run included',
      () async {
        // It does not say which dependencies were the user's, so even the
        // preview would promise a reversal the real run refuses.
        final root = Directory.systemTemp.createTempSync('plun_old_record_');
        addTearDown(() => root.deleteSync(recursive: true));
        _seedInstalledProject(root, pluginName: 'demo_plugin');
        final record = File(
          p.join(root.path, '.dowel', 'installed', 'demo_plugin.json'),
        );
        final decoded = jsonDecode(record.readAsStringSync()) as Map;
        record.writeAsStringSync(jsonEncode(decoded..remove('version')));
        final manifestPath = p.join(root.path, 'demo_install.yaml');
        _writeInstallYaml(manifestPath, 'demo_plugin');

        final cmd = _TestablePluginUninstallCommand(
          fakeProjectRoot: root.path,
          fakeInstallYamlPath: manifestPath,
        );
        final ctx = _ctxWith(
          _baseOpts(overrides: const {'dry-run': true}),
          positional: const ['demo_plugin'],
          signature: cmd.parsedSignature,
        );

        final exit = await cmd.handle(ctx);

        expect(exit, 1);
        final out = (ctx.output as BufferedOutput).content;
        expect(out, contains('"version"'));
        expect(out, contains('--force'));
      },
    );
  });
}

/// Test subclass for the "no install.yaml" failure mode — separate from
/// `_TestablePluginUninstallCommand` because the latter requires the path to
/// be non-nullable per its constructor contract.
class _TestablePluginUninstallCommandNoYaml extends PluginUninstallCommand {
  _TestablePluginUninstallCommandNoYaml({required this.fakeProjectRoot});

  final String fakeProjectRoot;

  @override
  String getProjectRoot() => fakeProjectRoot;

  @override
  Future<String?> resolveInstallYaml(String pluginName) async => null;

  @override
  bool promptConfirmation(DowelContext ctx, String pluginName) => true;
}

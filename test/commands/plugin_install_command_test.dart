import 'dart:convert';
import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:dowel/src/commands/helpers/bootstrap_command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

/// Builds a fake consumer project tree under [root] with the files
/// `plugin:install` validates before doing any work: pubspec.yaml listing the
/// plugin as a dep and .dart_tool/package_config.json resolving the plugin
/// name. With [scaffold] it also writes the `lib/app/_plugins.g.dart` barrel
/// that `dowel install` leaves behind.
///
/// @param root       The temp project root.
/// @param pluginName The plugin name to wire into both files.
/// @param scaffold   Whether to seed the `dowel install` scaffold barrel.
void _seedConsumerProject(
  Directory root, {
  required String pluginName,
  bool scaffold = false,
}) {
  // 1. pubspec.yaml — plugin listed under dependencies.
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(
    'name: consumer\n'
    'dependencies:\n'
    '  $pluginName: ^1.0.0\n',
  );

  // 2. .dart_tool/package_config.json — plugin resolvable.
  final pkgConfigDir = Directory(p.join(root.path, '.dart_tool'))
    ..createSync(recursive: true);
  File(p.join(pkgConfigDir.path, 'package_config.json')).writeAsStringSync(
    '{"packages":[{"name": "$pluginName"}]}\n',
  );

  // 3. lib/app/_plugins.g.dart: the barrel `dowel install` scaffolds.
  if (scaffold) {
    Directory(p.join(root.path, 'lib', 'app')).createSync(recursive: true);
    File(p.join(root.path, 'lib', 'app', '_plugins.g.dart'))
        .writeAsStringSync('// GENERATED\nfinal providers = <Object>[];\n');
  }
}

/// Writes an `install.yaml` manifest at [path] with the supplied
/// [pluginName]. Minimal valid manifest, no sections.
void _writeInstallYaml(String path, String pluginName) {
  File(path).writeAsStringSync('plugin_name: $pluginName\n');
}

/// Builds an [DowelContext] backed by a [MapInput] carrying the supplied
/// option / argument values + a [BufferedOutput] for output assertions.
///
/// @param options     Map of option-name → value.
/// @param positional  Positional arguments in declaration order.
/// @param signature   Optional [CommandSignature] for name-based positional
///                    lookup via `ctx.input.argument('name')`.
/// @return A bare [DowelContext] suitable for direct `handle()` invocation.
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

/// Records every [BootstrapCommandRunner.run] invocation so the auto-run tests
/// can assert the chained command + project root without spawning a real
/// subprocess.
class _RecordingBootstrapRunner implements BootstrapCommandRunner {
  String? bootstrapCommand;
  String? projectRoot;
  int callCount = 0;

  BootstrapRunResult returnResult = const BootstrapRunResult(
      outcome: BootstrapRunOutcome.invoked, exitCode: 0);

  /// When set, [run] throws this instead of returning, simulating a runtime
  /// failure (e.g. `dart` missing on PATH) so the best-effort path is covered.
  Object? throwOnRun;

  @override
  Future<BootstrapRunResult> run({
    required String bootstrapCommand,
    required String projectRoot,
  }) async {
    callCount++;
    this.bootstrapCommand = bootstrapCommand;
    this.projectRoot = projectRoot;
    if (throwOnRun != null) throw throwOnRun!;
    return returnResult;
  }
}

/// Test subclass that pins the project root to a temp dir AND lets each test
/// inject a custom install.yaml resolver so the path resolution does not have
/// to round-trip through the host's real Isolate.resolvePackageUri.
class _TestablePluginInstallCommand extends PluginInstallCommand {
  _TestablePluginInstallCommand({
    required this.fakeProjectRoot,
    this.fakeInstallYamlPath,
    this.fakeBootstrapRunner,
  });

  /// Pinned project root for the test invocation. Overrides the production
  /// [FileHelper.findProjectRoot] traversal so tests do not depend on the
  /// host package's pubspec.yaml location.
  final String fakeProjectRoot;

  /// Optional install.yaml path the resolver returns. When `null`, the
  /// resolver reports "no manifest found" so the direct registration fires.
  final String? fakeInstallYamlPath;

  /// Optional bootstrap runner override so auto-run tests can record the
  /// chained command without spawning a real subprocess.
  final BootstrapCommandRunner? fakeBootstrapRunner;

  @override
  String getProjectRoot() => fakeProjectRoot;

  @override
  Future<String?> resolveInstallYaml(String pluginName) async {
    return fakeInstallYamlPath;
  }

  @override
  BootstrapCommandRunner buildBootstrapRunner() =>
      fakeBootstrapRunner ?? super.buildBootstrapRunner();
}

void main() {
  group('PluginInstallCommand — signature DSL', () {
    test('inherits the 4 base flags via DowelInstallCommand.baseFlags', () {
      final cmd = PluginInstallCommand();
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

    test('declares its own plugin-specific options on top of the base flags',
        () {
      final cmd = PluginInstallCommand();
      final parsed = cmd.parsedSignature!;
      final optionNames = parsed.options.map((o) => o.name).toSet();

      expect(
        optionNames,
        containsAll(<String>['bootstrap-command', 'use-yaml-only']),
      );
      expect(optionNames, isNot(contains('provider')));
    });

    test('extends DowelInstallCommand (CommandBoot.none)', () {
      final cmd = PluginInstallCommand();
      expect(cmd, isA<DowelInstallCommand>());
      expect(cmd.boot, CommandBoot.none);
    });

    test('pluginName(ctx) derives from the positional name argument', () {
      final cmd = PluginInstallCommand();
      final ctx = _ctxWith(
        const <String, dynamic>{},
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      expect(cmd.pluginName(ctx), 'magic_logger');
    });
  });

  group('PluginInstallCommand: direct registration (no install.yaml)', () {
    test('records the plugin in plugins.json and regenerates _plugins.g.dart',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_direct_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger', scaffold: true);

      final cmd = _TestablePluginInstallCommand(fakeProjectRoot: root.path);
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': false,
          'dry-run': false,
          'non-interactive': false,
          'use-yaml-only': false,
          'bootstrap-command': null,
        },
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      final out = (ctx.output as BufferedOutput).content;
      expect(out, contains('via the dowel scaffold'));

      final registry = jsonDecode(
        File(p.join(root.path, '.dowel', 'plugins.json')).readAsStringSync(),
      ) as Map<String, dynamic>;
      final plugins = registry['plugins'] as List<dynamic>;
      expect(plugins, hasLength(1));
      expect(
        (plugins.single as Map<String, dynamic>)['providerClass'],
        'MagicLoggerDowelProvider',
      );

      final barrel = File(p.join(root.path, 'lib', 'app', '_plugins.g.dart'))
          .readAsStringSync();
      expect(barrel, contains('MagicLoggerDowelProvider'));
    });

    test('a second run keeps exactly one plugins.json entry', () async {
      final root = Directory.systemTemp.createTempSync('plinst_idem_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger', scaffold: true);

      const opts = <String, dynamic>{
        'force': false,
        'no-bootstrap': false,
        'dry-run': false,
        'non-interactive': false,
        'use-yaml-only': false,
        'bootstrap-command': null,
      };

      // A fresh command per run: the second install must be idempotent on
      // disk, not because the first instance remembered anything.
      Future<void> runInstall() {
        final cmd = _TestablePluginInstallCommand(fakeProjectRoot: root.path);
        return cmd.handle(_ctxWith(opts,
            positional: const ['magic_logger'],
            signature: cmd.parsedSignature));
      }

      await runInstall();
      await runInstall();

      final registry = jsonDecode(
        File(p.join(root.path, '.dowel', 'plugins.json')).readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(registry['plugins'] as List<dynamic>, hasLength(1));

      final barrel = File(p.join(root.path, 'lib', 'app', '_plugins.g.dart'))
          .readAsStringSync();
      expect('MagicLoggerDowelProvider('.allMatches(barrel), hasLength(1));
      expect("import 'package:magic_logger/".allMatches(barrel), hasLength(1));
    });

    test(
        'install purges .dowel/cli-bundle and .dowel/build.stamp '
        'after successful registration', () async {
      // Issue #9 GAP A: after `plugin:install` regenerates lib/app/_plugins.g.dart
      // the next `./bin/dowel` invocation must rebuild the AOT bundle. Purging
      // .dowel/cli-bundle/ and .dowel/build.stamp forces the staleness check
      // to rebuild.
      final root = Directory.systemTemp.createTempSync('plinst_cachepurge_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger', scaffold: true);

      // 1. Pre-create the cache artefacts that the post-install hook must purge.
      final cacheDir = Directory(p.join(root.path, '.dowel', 'cli-bundle'))
        ..createSync(recursive: true);
      File(p.join(cacheDir.path, 'sentinel')).writeAsStringSync('');
      File(p.join(root.path, '.dowel', 'build.stamp'))
          .writeAsStringSync('deadbeef:3.4.0');

      final cmd = _TestablePluginInstallCommand(fakeProjectRoot: root.path);
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': true,
          'dry-run': false,
          'non-interactive': false,
          'use-yaml-only': false,
          'bootstrap-command': null,
        },
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      // 2. Both cache artefacts must be gone after a successful install.
      expect(
        Directory(p.join(root.path, '.dowel', 'cli-bundle')).existsSync(),
        isFalse,
        reason:
            'install must purge .dowel/cli-bundle/ so the next ./bin/dowel rebuilds',
      );
      expect(
        File(p.join(root.path, '.dowel', 'build.stamp')).existsSync(),
        isFalse,
        reason:
            'install must purge .dowel/build.stamp so needs_build() trips on next call',
      );
    });

    test('errors when plugin missing from pubspec.yaml', () async {
      final root = Directory.systemTemp.createTempSync('plinst_nodep_');
      addTearDown(() => root.deleteSync(recursive: true));
      // Seed everything for "other_plugin" but request install of "magic_logger".
      _seedConsumerProject(root, pluginName: 'other_plugin');

      final cmd = _TestablePluginInstallCommand(fakeProjectRoot: root.path);
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': false,
          'dry-run': false,
          'non-interactive': false,
          'use-yaml-only': false,
          'bootstrap-command': null,
        },
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 1);
      final out = (ctx.output as BufferedOutput).content;
      expect(out, contains('[ERROR]'));
      expect(out, contains('not listed in pubspec.yaml'));
    });

    test('--dry-run previews the registration and writes nothing', () async {
      final root = Directory.systemTemp.createTempSync('plinst_direct_dry_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger', scaffold: true);
      final barrel = File(p.join(root.path, 'lib', 'app', '_plugins.g.dart'));
      final before = barrel.readAsStringSync();

      final cmd = _TestablePluginInstallCommand(fakeProjectRoot: root.path);
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': false,
          'dry-run': true,
          'non-interactive': false,
          'use-yaml-only': false,
          'bootstrap-command': null,
        },
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);

      expect(exit, 0);
      expect((ctx.output as BufferedOutput).content, contains('Dry run'));
      expect(
        File(p.join(root.path, '.dowel', 'plugins.json')).existsSync(),
        isFalse,
      );
      expect(barrel.readAsStringSync(), before);
    });

    test('a failed registration exits non-zero instead of reporting success',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_direct_fail_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger', scaffold: true);
      // A directory where the registry file belongs makes the write fail.
      Directory(p.join(root.path, '.dowel', 'plugins.json'))
          .createSync(recursive: true);

      final cmd = _TestablePluginInstallCommand(fakeProjectRoot: root.path);
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': false,
          'dry-run': false,
          'non-interactive': false,
          'use-yaml-only': false,
          'bootstrap-command': null,
        },
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);

      expect(exit, 1);
      expect(
        (ctx.output as BufferedOutput).content,
        isNot(contains('Registered "magic_logger"')),
      );
    });

    test('--bootstrap-command chains the command after a direct registration',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_direct_boot_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger', scaffold: true);

      final runner = _RecordingBootstrapRunner();
      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeBootstrapRunner: runner,
      );
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': false,
          'dry-run': false,
          'non-interactive': false,
          'use-yaml-only': false,
          'bootstrap-command': 'logger:install',
        },
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);

      expect(exit, 0);
      expect(runner.callCount, 1);
      expect(runner.bootstrapCommand, 'logger:install');
    });

    test(
        '--no-bootstrap keeps the chained command out of a direct registration',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_direct_nob_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger', scaffold: true);

      final runner = _RecordingBootstrapRunner();
      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeBootstrapRunner: runner,
      );
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': true,
          'dry-run': false,
          'non-interactive': false,
          'use-yaml-only': false,
          'bootstrap-command': 'logger:install',
        },
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);

      expect(exit, 0);
      expect(runner.callCount, 0);
      expect(
        (ctx.output as BufferedOutput).content,
        contains('Bootstrap with: dowel logger:install'),
      );
    });

    test('errors toward `dowel install` when there is no scaffold', () async {
      final root = Directory.systemTemp.createTempSync('plinst_no_scaffold_');
      addTearDown(() => root.deleteSync(recursive: true));

      // Only the preflight prerequisites: no lib/app/_plugins.g.dart, and a
      // bin/dowel.dart that must NOT be mistaken for a consumer wrapper.
      _seedConsumerProject(root, pluginName: 'magic_logger');
      Directory(p.join(root.path, 'bin')).createSync(recursive: true);
      File(p.join(root.path, 'bin', 'dowel.dart'))
          .writeAsStringSync('void main() {}\n');

      final cmd = _TestablePluginInstallCommand(fakeProjectRoot: root.path);
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': false,
          'dry-run': false,
          'non-interactive': false,
          'use-yaml-only': false,
          'bootstrap-command': null,
        },
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 1);
      final out = (ctx.output as BufferedOutput).content;
      expect(out, contains('No dowel scaffold found'));
      expect(out, contains('dowel install'));
      expect(
        File(p.join(root.path, '.dowel', 'plugins.json')).existsSync(),
        isFalse,
      );
    });
  });

  group('PluginInstallCommand — install.yaml branch', () {
    test('routes through ManifestInstaller when install.yaml is found',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_yaml_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'demo_plugin');

      // Provide a minimal install.yaml.
      final manifestPath = p.join(root.path, 'demo_install.yaml');
      _writeInstallYaml(manifestPath, 'demo_plugin');

      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': true,
          'dry-run': false,
          'non-interactive': true,
          'use-yaml-only': false,
          'bootstrap-command': null,
        },
        positional: const ['demo_plugin'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);

      // Minimal manifest has no ops to apply; commit returns Success(0).
      expect(exit, 0);
      final out = (ctx.output as BufferedOutput).content;
      // Reaching this point proves the manifest branch fired: the direct
      // registration prints its own "via the dowel scaffold" line.
      expect(out, isNot(contains('via the dowel scaffold')),
          reason: 'install.yaml branch must NOT do the direct registration.');
    });

    test('--dry-run flows through to ManifestInstaller without disk writes',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_dryrun_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'demo_plugin');

      final manifestPath = p.join(root.path, 'demo_install.yaml');
      _writeInstallYaml(manifestPath, 'demo_plugin');

      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': true,
          'dry-run': true,
          'non-interactive': true,
          'use-yaml-only': false,
          'bootstrap-command': null,
        },
        positional: const ['demo_plugin'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      // Dry-run never writes the install record.
      final recordPath =
          p.join(root.path, '.dowel', 'installed', 'demo_plugin.json');
      expect(File(recordPath).existsSync(), isFalse);
    });

    test('--use-yaml-only fails when install.yaml is absent', () async {
      final root = Directory.systemTemp.createTempSync('plinst_yamlonly_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger');

      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: null,
      );
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': false,
          'dry-run': false,
          'non-interactive': false,
          'use-yaml-only': true,
          'bootstrap-command': null,
        },
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 1);
      final out = (ctx.output as BufferedOutput).content;
      expect(out, contains('[ERROR]'));
      expect(out, contains('install.yaml'));
    });

    test('registers the plugin directly when install.yaml is not found',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_fallback_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger', scaffold: true);

      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        // No install.yaml → resolver returns null → direct registration.
        fakeInstallYamlPath: null,
      );
      final ctx = _ctxWith(
        const <String, dynamic>{
          'force': false,
          'no-bootstrap': true,
          'dry-run': false,
          'non-interactive': false,
          'use-yaml-only': false,
          'bootstrap-command': null,
        },
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      // Direct registration ran → the plugin is in plugins.json.
      final registry =
          File(p.join(root.path, '.dowel', 'plugins.json')).readAsStringSync();
      expect(registry, contains('MagicLoggerDowelProvider'));
    });
  });

  group(
      'PluginInstallCommand — manifest flow → plugins.json registration '
      '(Change F)', () {
    // -------------------------------------------------------------------------
    // Local fixtures shared by the Change F tests below.
    // -------------------------------------------------------------------------

    /// Seeds `<root>/lib/app/.keep` so [PluginsRefreshCommand]'s
    /// `directoryExists(lib/app)` probe (delegated to `Directory.existsSync`
    /// in production) passes. Mirrors the in-memory helper in
    /// `plugins_refresh_command_test.dart:_seedLibApp`.
    void seedLibApp(Directory root) {
      final libAppDir = Directory(p.join(root.path, 'lib', 'app'))
        ..createSync(recursive: true);
      File(p.join(libAppDir.path, '.keep')).writeAsStringSync('');
    }

    /// Builds the standard success-path options map for the manifest flow.
    Map<String, dynamic> manifestOpts({bool dryRun = false}) {
      return <String, dynamic>{
        'force': false,
        'no-bootstrap': true,
        'dry-run': dryRun,
        'non-interactive': true,
        'use-yaml-only': false,
        'bootstrap-command': null,
      };
    }

    test('successful manifest install writes plugins.json entry for the plugin',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_reg_success_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger');
      seedLibApp(root);

      // Minimal manifest: no ops, commit returns Success(0), then the Change F
      // _registerDowelProvider step fires.
      final manifestPath = p.join(root.path, 'install.yaml');
      _writeInstallYaml(manifestPath, 'magic_logger');

      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final ctx = _ctxWith(
        manifestOpts(),
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      // 1. Registry file landed on disk via PluginsRegistryFile.write.
      final registryPath = p.join(root.path, '.dowel', 'plugins.json');
      expect(File(registryPath).existsSync(), isTrue,
          reason:
              '_registerDowelProvider must persist plugins.json on Success');

      // 2. Entry shape matches the convention encoded in _registerDowelProvider.
      final registry =
          await PluginsRegistryFile(const RealFs(), root.path).read();
      expect(registry.plugins, hasLength(1));
      final entry = registry.plugins.single;
      expect(entry.name, 'magic_logger');
      expect(entry.providerImport, 'package:magic_logger/cli.dart');
      expect(entry.providerClass, 'MagicLoggerDowelProvider');
      expect(DateTime.tryParse(entry.registeredAt), isNotNull,
          reason: 'registeredAt must be parseable ISO-8601');
    });

    test(
        'successful manifest install regenerates lib/app/_plugins.g.dart to '
        'include the plugin', () async {
      final root = Directory.systemTemp.createTempSync('plinst_reg_codegen_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger');
      seedLibApp(root);

      final manifestPath = p.join(root.path, 'install.yaml');
      _writeInstallYaml(manifestPath, 'magic_logger');

      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final ctx = _ctxWith(
        manifestOpts(),
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      final generatedPath = p.join(root.path, 'lib', 'app', '_plugins.g.dart');
      expect(File(generatedPath).existsSync(), isTrue,
          reason: 'PluginsRefreshCommand must regenerate _plugins.g.dart');

      final generated = File(generatedPath).readAsStringSync();
      expect(
        generated,
        contains(
          "import 'package:magic_logger/cli.dart' show MagicLoggerDowelProvider;",
        ),
      );
      expect(generated, contains('MagicLoggerDowelProvider(),'));
      expect(generated,
          contains('List<DowelServiceProvider> autoDiscoveredProviders()'));
    });

    test('dry-run skips plugin registration entirely', () async {
      final root = Directory.systemTemp.createTempSync('plinst_reg_dryrun_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'demo_plugin');
      // No lib/app/ seed — dry-run must short-circuit BEFORE plugins:refresh
      // gets a chance to walk into the missing directory.

      final manifestPath = p.join(root.path, 'install.yaml');
      _writeInstallYaml(manifestPath, 'demo_plugin');

      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final ctx = _ctxWith(
        manifestOpts(dryRun: true),
        positional: const ['demo_plugin'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      // The dry-run guard inside _runManifestFlow short-circuits
      // _registerDowelProvider, so neither plugins.json nor _plugins.g.dart
      // should appear.
      final registryPath = p.join(root.path, '.dowel', 'plugins.json');
      expect(File(registryPath).existsSync(), isFalse,
          reason: '--dry-run must NOT write the plugins registry');
      final generatedPath = p.join(root.path, 'lib', 'app', '_plugins.g.dart');
      expect(File(generatedPath).existsSync(), isFalse,
          reason: '--dry-run must NOT trigger plugins:refresh codegen');
    });

    test(
        'repeated install is idempotent — single entry, single '
        '_plugins.g.dart import', () async {
      final root = Directory.systemTemp.createTempSync('plinst_reg_idem_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger');
      seedLibApp(root);

      final manifestPath = p.join(root.path, 'install.yaml');
      _writeInstallYaml(manifestPath, 'magic_logger');

      // Two independent command instances share the same project root so we
      // exercise the addPlugin replace-by-name path, not a single-instance
      // optimisation.
      final cmdA = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final cmdB = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final opts = manifestOpts();

      final exitA = await cmdA.handle(_ctxWith(opts,
          positional: const ['magic_logger'], signature: cmdA.parsedSignature));
      final exitB = await cmdB.handle(_ctxWith(opts,
          positional: const ['magic_logger'], signature: cmdB.parsedSignature));

      expect(exitA, 0);
      expect(exitB, 0);

      // 1. plugins.json must hold exactly one entry for magic_logger after
      //    two runs. PluginsRegistryFile.addPlugin replaces by name.
      final registry =
          await PluginsRegistryFile(const RealFs(), root.path).read();
      expect(
        registry.plugins.where((e) => e.name == 'magic_logger').length,
        1,
        reason: 'addPlugin must replace by name, not duplicate',
      );

      // 2. _plugins.g.dart must hold exactly one import line + one
      //    constructor call for the plugin (deterministic codegen).
      final generated = File(p.join(
        root.path,
        'lib',
        'app',
        '_plugins.g.dart',
      )).readAsStringSync();
      final importMatches = RegExp(
        "import 'package:magic_logger/cli.dart' show MagicLoggerDowelProvider;",
      ).allMatches(generated);
      expect(importMatches, hasLength(1),
          reason: 'codegen must emit a single import per plugin');
      final ctorMatches =
          RegExp(r'MagicLoggerDowelProvider\(\),').allMatches(generated);
      expect(ctorMatches, hasLength(1),
          reason: 'codegen must emit a single constructor call per plugin');
    });

    test(
        'plugins.json write failure surfaces ctx.output.warning but does not '
        'fail the install', () async {
      final root = Directory.systemTemp.createTempSync('plinst_reg_warn_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger');
      seedLibApp(root);

      // 1. Pre-create .dowel/plugins.json AS A DIRECTORY so the atomic
      //    `_fs.rename(tmpPath, registryPath)` inside PluginsRegistryFile.write
      //    fails with FileSystemException ("Cannot rename file ... is a
      //    directory"). Portable across POSIX (Linux/macOS) without chmod.
      Directory(p.join(root.path, '.dowel', 'plugins.json'))
          .createSync(recursive: true);

      final manifestPath = p.join(root.path, 'install.yaml');
      _writeInstallYaml(manifestPath, 'magic_logger');

      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final ctx = _ctxWith(
        manifestOpts(),
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);

      // 2. Manifest install itself succeeded, so handle() still returns 0 —
      //    the try-catch inside _registerDowelProvider must swallow the
      //    rename failure into a warning, never an error.
      expect(exit, 0,
          reason: 'auto-registration failure must NOT fail the install');
      final out = (ctx.output as BufferedOutput).content;
      expect(out, contains('auto-registration failed:'),
          reason: 'try-catch must surface a user-facing warning');
    });

    test('PascalCase derivation handles snake_case plugin name correctly',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_reg_pascal_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'my_test_logger');
      seedLibApp(root);

      final manifestPath = p.join(root.path, 'install.yaml');
      _writeInstallYaml(manifestPath, 'my_test_logger');

      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
      );
      final ctx = _ctxWith(
        manifestOpts(),
        positional: const ['my_test_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      // 1. plugins.json entry uses fully-collapsed PascalCase
      //    (MyTestLogger, not My_test_logger).
      final registryJson = jsonDecode(File(p.join(
        root.path,
        '.dowel',
        'plugins.json',
      )).readAsStringSync()) as Map<String, dynamic>;
      final entries = registryJson['plugins'] as List<dynamic>;
      expect(entries, hasLength(1));
      expect((entries.single as Map<String, dynamic>)['providerClass'],
          'MyTestLoggerDowelProvider');

      // 2. Generated codegen surfaces the same PascalCase identifier so the
      //    emitted Dart file actually compiles.
      final generated = File(p.join(
        root.path,
        'lib',
        'app',
        '_plugins.g.dart',
      )).readAsStringSync();
      expect(generated, contains('MyTestLoggerDowelProvider'));
      expect(generated, isNot(contains('My_test_loggerDowelProvider')),
          reason: 'PascalCase derivation must collapse all snake_case parts');
    });
  });

  group('PluginInstallCommand — bootstrap_command auto-run (#4a)', () {
    /// Seeds `<root>/lib/app/.keep` so [PluginsRefreshCommand]'s directory
    /// probe passes during the manifest flow's registration step.
    void seedLibApp(Directory root) {
      Directory(p.join(root.path, 'lib', 'app')).createSync(recursive: true);
      File(p.join(root.path, 'lib', 'app', '.keep')).writeAsStringSync('');
    }

    /// Writes an install.yaml that declares a `bootstrap_command`.
    void writeManifestWithBootstrap(String path, String pluginName) {
      File(path).writeAsStringSync(
        'plugin_name: $pluginName\n'
        'bootstrap_command: starter:install\n',
      );
    }

    /// Standard non-interactive options map for the manifest flow.
    Map<String, dynamic> opts({bool noBootstrap = false}) {
      return <String, dynamic>{
        'force': false,
        'no-bootstrap': noBootstrap,
        'dry-run': false,
        'non-interactive': true,
        'use-yaml-only': false,
        'bootstrap-command': null,
      };
    }

    test(
        '(a) a manifest declaring bootstrap_command triggers the subprocess '
        'invocation with the declared command', () async {
      final root = Directory.systemTemp.createTempSync('plinst_boot_run_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_starter');
      seedLibApp(root);

      final manifestPath = p.join(root.path, 'install.yaml');
      writeManifestWithBootstrap(manifestPath, 'magic_starter');

      final runner = _RecordingBootstrapRunner();
      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
        fakeBootstrapRunner: runner,
      );
      final ctx = _ctxWith(
        opts(),
        positional: const ['magic_starter'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      expect(runner.callCount, 1, reason: 'auto-run must fire exactly once');
      expect(runner.bootstrapCommand, 'starter:install');
      expect(runner.projectRoot, root.path);

      // The hint-only message must NOT fire when the command auto-ran.
      final out = (ctx.output as BufferedOutput).content;
      expect(out, isNot(contains('Bootstrap with: dowel')));
    });

    test('(b) --no-bootstrap suppresses the auto-run entirely', () async {
      final root = Directory.systemTemp.createTempSync('plinst_boot_skip_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_starter');
      seedLibApp(root);

      final manifestPath = p.join(root.path, 'install.yaml');
      writeManifestWithBootstrap(manifestPath, 'magic_starter');

      final runner = _RecordingBootstrapRunner();
      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
        fakeBootstrapRunner: runner,
      );
      final ctx = _ctxWith(
        opts(noBootstrap: true),
        positional: const ['magic_starter'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      expect(runner.callCount, 0,
          reason: '--no-bootstrap must NOT invoke the bootstrap command');
    });

    test('(c) a manifest with no bootstrap_command invokes nothing', () async {
      final root = Directory.systemTemp.createTempSync('plinst_boot_none_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_logger');
      seedLibApp(root);

      // Minimal manifest: no bootstrap_command declared.
      final manifestPath = p.join(root.path, 'install.yaml');
      _writeInstallYaml(manifestPath, 'magic_logger');

      final runner = _RecordingBootstrapRunner();
      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
        fakeBootstrapRunner: runner,
      );
      final ctx = _ctxWith(
        opts(),
        positional: const ['magic_logger'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      expect(runner.callCount, 0,
          reason: 'no bootstrap_command means nothing to auto-run');
    });

    test('the --bootstrap-command override wins over the manifest declaration',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_boot_override_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_starter');
      seedLibApp(root);

      final manifestPath = p.join(root.path, 'install.yaml');
      writeManifestWithBootstrap(manifestPath, 'magic_starter');

      final runner = _RecordingBootstrapRunner();
      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
        fakeBootstrapRunner: runner,
      );
      final overrideOpts = opts()..['bootstrap-command'] = 'starter:configure';
      final ctx = _ctxWith(
        overrideOpts,
        positional: const ['magic_starter'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      expect(runner.bootstrapCommand, 'starter:configure',
          reason: '--bootstrap-command must override the manifest value');
    });

    test('falls back to the hint message when no dispatcher is resolvable',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_boot_hint_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_starter');
      seedLibApp(root);

      final manifestPath = p.join(root.path, 'install.yaml');
      writeManifestWithBootstrap(manifestPath, 'magic_starter');

      final runner = _RecordingBootstrapRunner()
        ..returnResult = const BootstrapRunResult(
          outcome: BootstrapRunOutcome.notResolvable,
        );
      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
        fakeBootstrapRunner: runner,
      );
      final ctx = _ctxWith(
        opts(),
        positional: const ['magic_starter'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0);

      expect(runner.callCount, 1,
          reason: 'the runner is consulted before falling back to the hint');
      final out = (ctx.output as BufferedOutput).content;
      expect(out, contains('Bootstrap with: dowel starter:install'),
          reason: 'when the runner cannot resolve a dispatcher, emit the hint');
    });

    test('a runner failure is best-effort: install succeeds, warns, hints',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_boot_throw_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_starter');
      seedLibApp(root);

      final manifestPath = p.join(root.path, 'install.yaml');
      writeManifestWithBootstrap(manifestPath, 'magic_starter');

      final runner = _RecordingBootstrapRunner()
        ..throwOnRun = ProcessException('dart', <String>[], 'not found');
      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
        fakeBootstrapRunner: runner,
      );
      final ctx = _ctxWith(
        opts(),
        positional: const ['magic_starter'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0,
          reason: 'a post-install auto-run failure must not fail the install');
      expect(runner.callCount, 1);
      final out = (ctx.output as BufferedOutput).content;
      expect(out, contains('Could not auto-run the bootstrap command'));
      expect(out, contains('Bootstrap with: dowel starter:install'),
          reason: 'falls back to the manual hint after a runner failure');
    });

    test('a non-zero bootstrap exit warns + hints instead of implying success',
        () async {
      final root = Directory.systemTemp.createTempSync('plinst_boot_nonzero_');
      addTearDown(() => root.deleteSync(recursive: true));
      _seedConsumerProject(root, pluginName: 'magic_starter');
      seedLibApp(root);

      final manifestPath = p.join(root.path, 'install.yaml');
      writeManifestWithBootstrap(manifestPath, 'magic_starter');

      final runner = _RecordingBootstrapRunner()
        ..returnResult = const BootstrapRunResult(
          outcome: BootstrapRunOutcome.invoked,
          exitCode: 64,
          stderr: 'Unknown command: starter:install',
        );
      final cmd = _TestablePluginInstallCommand(
        fakeProjectRoot: root.path,
        fakeInstallYamlPath: manifestPath,
        fakeBootstrapRunner: runner,
      );
      final ctx = _ctxWith(
        opts(),
        positional: const ['magic_starter'],
        signature: cmd.parsedSignature,
      );

      final exit = await cmd.handle(ctx);
      expect(exit, 0,
          reason: 'a failed auto-run is best-effort, install still succeeds');
      final out = (ctx.output as BufferedOutput).content;
      expect(out, contains('exited with code 64'),
          reason: 'a non-zero bootstrap exit must be surfaced, not hidden');
      expect(out, contains('Unknown command: starter:install'),
          reason: 'the captured stderr explains the failure');
      expect(out, contains('Bootstrap with: dowel starter:install'),
          reason: 'falls back to the manual hint so the operator can recover');
    });
  });
}

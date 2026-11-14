import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../console/dowel_context.dart';
import '../console/string_helper.dart';
import '../helpers/file_helper.dart';
import '../installer/dowel_install_command.dart';
import '../installer/install_exception.dart';
import '../installer/install_manifest.dart';
import '../installer/install_transaction.dart';
import '../installer/manifest_installer.dart';
import '../installer/manifest_parser.dart';
import '../installer/plugins_registry_file.dart';
import '../installer/virtual_fs.dart';
import 'helpers/bootstrap_command_runner.dart';
import 'plugins_refresh_command.dart';

/// `plugin:install <name>`, register a third-party dowel plugin into the
/// consumer project.
///
/// Two flows live in this command:
///
///   1. **Manifest flow** (preferred): when the plugin ships an
///      `install.yaml` at its package root or `assets/install.yaml`, parse
///      it via [ManifestParser], translate it via [ManifestInstaller], and
///      commit through the [PluginInstaller] DSL. This is the standard
///      Plugin Authoring Guide path (declarative; supports dry-run, conflict
///      detection, install records, reverse on uninstall).
///
///   2. **Direct registration**: when no `install.yaml` is found and the
///      consumer scaffold from `dowel install` is present
///      (`lib/app/_plugins.g.dart`), record the plugin in
///      `.dowel/plugins.json` and regenerate `_plugins.g.dart`.
///
/// Pass `--use-yaml-only` to make the manifest flow strict: when no
/// manifest is found the command errors out instead of registering directly.
///
/// Plugin authoring conventions assumed by the direct registration:
///   - Plugin exports a CLI barrel at `package:<name>/cli.dart`.
///   - Plugin declares a provider class named `<PascalCaseName>DowelProvider`
///     in that barrel.
///
/// Pre-flight validation (both flows):
///   - The package must be listed in the consumer's `pubspec.yaml`.
///   - The package must be resolvable via
///     `.dart_tool/package_config.json` (so `flutter pub get` ran).
///
/// Dart has no auto-discovery for service providers (no `dart:mirrors` under
/// AOT, no Laravel-style `composer.json` extras). This command IS the
/// substitute: the consumer adds the dep + runs `plugin:install <name>` once
/// and never touches the generated wrapper by hand.
class PluginInstallCommand extends DowelInstallCommand {
  /// Public default constructor. Test fixtures subclass + override
  /// [getProjectRoot] / [resolveInstallYaml] to inject deterministic paths
  /// without depending on the host's filesystem layout.
  PluginInstallCommand();

  @override
  String get signature =>
      'plugin:install '
      '$baseFlags'
      '{name : Plugin pubspec package name (e.g. magic_logger)} '
      '{--bootstrap-command= : Plugin install sub-command to chain after registration (e.g. logger:install)} '
      '{--use-yaml-only : Fail if install.yaml not found instead of registering the plugin directly}';

  @override
  String get description =>
      'Register a third-party dowel plugin (install.yaml manifest preferred; '
      'direct registration into the dowel scaffold otherwise).';

  @override
  String pluginName(DowelContext ctx) =>
      (ctx.input.argument('name') ?? '').toString();

  /// Resolves the consumer project root. Hook for test subclasses; production
  /// path defers to [FileHelper.findProjectRoot].
  ///
  /// @return Absolute path to the directory containing the consumer's
  ///         `pubspec.yaml`.
  @visibleForTesting
  String getProjectRoot() => FileHelper.findProjectRoot();

  /// Resolves the plugin's `install.yaml` location, or `null` when the
  /// plugin ships no manifest.
  ///
  /// Resolution strategy (canonical Dart approach used elsewhere in this
  /// package, see magic_logger install_command for the prior art):
  ///   1. Resolve `package:<pluginName>/cli.dart` via [Isolate.resolvePackageUri].
  ///   2. Walk two directories up from `lib/cli.dart` to reach the plugin
  ///      root.
  ///   3. Check `<root>/install.yaml` first; fall back to
  ///      `<root>/assets/install.yaml`.
  ///
  /// Returns `null` for any failure mode (URI scheme not file, no candidate
  /// file present, resolution exception). Callers treat `null` as "no
  /// manifest" and register the plugin directly (or fail when
  /// `--use-yaml-only` is set).
  ///
  /// @param pluginName  The plugin's pubspec package name.
  /// @return Absolute path to the install.yaml, or `null` when none found.
  @visibleForTesting
  Future<String?> resolveInstallYaml(String pluginName) async {
    final resolved = await Isolate.resolvePackageUri(
      Uri.parse('package:$pluginName/cli.dart'),
    );
    if (resolved == null || resolved.scheme != 'file') return null;

    // resolved → <plugin_root>/lib/cli.dart; two dirname() calls back out.
    final libCli = resolved.toFilePath();
    final pluginRoot = p.dirname(p.dirname(libCli));

    final atRoot = p.join(pluginRoot, 'install.yaml');
    if (File(atRoot).existsSync()) return atRoot;

    final atAssets = p.join(pluginRoot, 'assets', 'install.yaml');
    if (File(atAssets).existsSync()) return atAssets;

    return null;
  }

  @override
  Future<int> handle(DowelContext ctx) async {
    // 1. Validate the positional name argument first so the rest of the
    //    handler can rely on a non-empty plugin name.
    final name = pluginName(ctx);
    if (name.isEmpty) {
      ctx.output.error('Missing required argument: name.');
      return 1;
    }

    // 2. Run the shared pre-flight (pubspec dep + package_config).
    final root = getProjectRoot();
    final preflight = _preflight(ctx, root: root, name: name);
    if (preflight != 0) return preflight;
    final orphaned = _orphanedBarrelImports(root);
    if (orphaned.isNotEmpty) {
      ctx.output.error(
        'lib/app/_plugins.g.dart registers providers from '
        '${orphaned.join(', ')}, but .dowel/plugins.json, the registry it is '
        'generated from, is missing. Installing now would regenerate the '
        'barrel without them. Restore .dowel/plugins.json from version '
        'control (commit it; only .dowel/cli-bundle/, .dowel/build.stamp and '
        '.dowel/.dowel.lock/ are cache), then retry.',
      );
      return 1;
    }

    // 3. Resolve the plugin's install.yaml. When found, route to the
    //    manifest flow; otherwise honour --use-yaml-only or register the
    //    plugin directly.
    final manifestPath = await resolveInstallYaml(name);
    if (manifestPath != null) {
      return _runManifestFlow(ctx, manifestPath: manifestPath);
    }

    if (isUseYamlOnly(ctx)) {
      ctx.output.error(
        'No install.yaml found for plugin "$name" and --use-yaml-only '
        'was passed. Either remove --use-yaml-only to register the plugin '
        'directly, or add an install.yaml manifest to the plugin (see '
        'doc/plugins/install-yaml.md).',
      );
      return 1;
    }

    // 4. Generic plugin (no install.yaml): needs the consumer scaffold from
    //    `dowel install` (lib/app/_plugins.g.dart). Write directly to
    //    .dowel/plugins.json and refresh _plugins.g.dart, the manifest-less
    //    parallel of the manifest-flow `_registerDowelProvider` step.
    if (!File(p.join(root, 'lib', 'app', '_plugins.g.dart')).existsSync()) {
      ctx.output.error(
        'No dowel scaffold found at ${p.join(root, 'lib', 'app')}. '
        'Run `dart run dowel install` to scaffold bin/dispatcher.dart and '
        '`lib/app/_plugins.g.dart`, then retry.',
      );
      return 1;
    }

    if (isDryRun(ctx)) {
      ctx.output.info(
        'Dry run: would register "$name" in .dowel/plugins.json and '
        'regenerate lib/app/_plugins.g.dart. Nothing was written.',
      );
      return 0;
    }

    // 5. A failed registration is the only thing this route does, so it must
    //    not report success. The manifest route keeps it best-effort because
    //    its install already committed.
    final registered = await _registerDowelProvider(ctx, name: name);
    if (!registered) return 1;
    ctx.output.success(
      'Registered "$name" via the dowel scaffold (no install.yaml needed).',
    );

    // 6. A bootstrap command can only come from --bootstrap-command here,
    //    since there is no manifest to declare one.
    await _runBootstrapCommand(ctx);
    return 0;
  }

  /// Returns `true` when the operator passed `--use-yaml-only`.
  ///
  /// @param ctx  The active [DowelContext] handed to [handle].
  /// @return The boolean value of the `--use-yaml-only` flag.
  bool isUseYamlOnly(DowelContext ctx) =>
      ctx.input.option('use-yaml-only') as bool? ?? false;

  // ---------------------------------------------------------------------------
  // Pre-flight
  // ---------------------------------------------------------------------------

  /// Runs the three pre-flight checks shared by both flows. Returns `0` when
  /// every check passes; non-zero exit code on the first failure (after
  /// writing the matching error to `ctx.output`).
  int _preflight(
    DowelContext ctx, {
    required String root,
    required String name,
  }) {
    // 1. Pubspec dep check, saves the user from a confusing import error.
    final pubspecPath = p.join(root, 'pubspec.yaml');
    if (File(pubspecPath).existsSync()) {
      final pubspec = File(pubspecPath).readAsStringSync();
      if (!pubspec.contains(RegExp('^\\s+$name:', multiLine: true))) {
        ctx.output.error(
          'Package "$name" is not listed in pubspec.yaml dependencies. '
          'Add it first, then run `flutter pub get`, then retry.',
        );
        return 1;
      }
    }

    // 2. Package resolvable in package_config.json.
    final packageConfig = File(
      p.join(root, '.dart_tool', 'package_config.json'),
    );
    if (packageConfig.existsSync() &&
        !packageConfig.readAsStringSync().contains('"name": "$name"')) {
      ctx.output.error(
        'Package "$name" is not in .dart_tool/package_config.json. '
        'Run `flutter pub get` first.',
      );
      return 1;
    }

    return 0;
  }

  /// The provider imports `lib/app/_plugins.g.dart` carries while
  /// `.dowel/plugins.json` is missing. A missing registry reads as empty, so
  /// registering into it regenerates the barrel with one plugin and drops
  /// every provider listed here. Empty when the registry exists, the barrel
  /// is absent, or it registers nothing.
  List<String> _orphanedBarrelImports(String root) {
    final barrel = File(p.join(root, 'lib', 'app', '_plugins.g.dart'));
    if (File(p.join(root, '.dowel', 'plugins.json')).existsSync() ||
        !barrel.existsSync()) {
      return const <String>[];
    }

    return <String>[
      for (final match in _providerImport.allMatches(barrel.readAsStringSync()))
        if (match.group(1) != 'package:dowel/dowel.dart') match.group(1)!,
    ];
  }

  /// An import line of the generated barrel, capturing its URI.
  static final RegExp _providerImport = RegExp(
    r"^import\s+'([^']+)'",
    multiLine: true,
  );

  // ---------------------------------------------------------------------------
  // Manifest flow
  // ---------------------------------------------------------------------------

  /// Parses the install.yaml at [manifestPath] and commits via
  /// [ManifestInstaller]. On a non-dry-run [InstallSuccess], also registers the
  /// plugin's [DowelServiceProvider] in `.dowel/plugins.json` and
  /// regenerates `lib/app/_plugins.g.dart` so commands appear in
  /// `dart run dowel list` without a separate `plugins:refresh` step.
  Future<int> _runManifestFlow(
    DowelContext ctx, {
    required String manifestPath,
  }) async {
    final InstallManifest manifest;
    try {
      manifest = ManifestParser.parseFile(manifestPath);
    } on FormatException catch (e) {
      ctx.output.error('install.yaml at $manifestPath: $e');
      return 1;
    } on ManifestValidationException catch (e) {
      ctx.output.error('install.yaml at $manifestPath: ${e.message}');
      return 1;
    }

    final installContext = buildContext(ctx);
    final installer = ManifestInstaller(installContext, manifest);
    final result = await installer.install(
      dryRun: isDryRun(ctx),
      force: isForce(ctx),
      nonInteractive: isNonInteractive(ctx),
    );

    final exit = _renderResultAndExit(ctx, result);
    if (result is InstallSuccess && !isDryRun(ctx)) {
      await _registerDowelProvider(ctx, name: manifest.pluginName);
      await _runBootstrapCommand(ctx, declared: manifest.bootstrapCommand);
    }
    return exit;
  }

  /// Auto-runs the plugin's declared `bootstrap_command` (or the
  /// `--bootstrap-command` override) as a fresh dispatcher subprocess after a
  /// successful manifest install.
  ///
  /// The bootstrap command is a PLUGIN command that was only just written to
  /// `lib/app/_plugins.g.dart` during this same install run, so it is NOT
  /// loaded in the current process. [BootstrapCommandRunner] reaches it by
  /// spawning a fresh `./bin/dowel` (or `dart run :dispatcher`)
  /// invocation, always forwarding `--non-interactive` so an interactive
  /// chained install cannot hang.
  ///
  /// Falls back to the one-line bootstrap hint when the operator passed
  /// `--no-bootstrap`, when no command is declared, or when no dispatcher is
  /// resolvable (neither `bin/dowel` nor `bin/dispatcher.dart` exists).
  Future<void> _runBootstrapCommand(
    DowelContext ctx, {
    String? declared,
  }) async {
    // 1. The --bootstrap-command override wins over the manifest declaration.
    final override = ctx.input.option('bootstrap-command') as String?;
    final bootstrap = override ?? declared;

    // 2. Nothing to do when no command is declared or the operator opted out.
    if (bootstrap == null) return;
    if (isSkipBootstrap(ctx)) {
      _emitBootstrapHint(ctx, bootstrap: bootstrap, skipped: true);
      return;
    }

    // 3. Spawn the chained command. This is a best-effort convenience step that
    //    runs AFTER the install + registration already succeeded, so a failure
    //    here (missing `dart` on PATH, non-executable `bin/dowel`, working-dir
    //    issues) must not crash `plugin:install`: catch it, warn, and fall back
    //    to the manual hint so the operator can still bootstrap by hand.
    try {
      final result = await buildBootstrapRunner().run(
        bootstrapCommand: bootstrap,
        projectRoot: getProjectRoot(),
      );

      // No dispatcher resolved: nothing ran, fall back to the manual hint.
      if (result.outcome == BootstrapRunOutcome.notResolvable) {
        _emitBootstrapHint(ctx, bootstrap: bootstrap, skipped: false);
        return;
      }

      // A subprocess ran but exited non-zero: surface the failure instead of
      // letting the manifest post_install message imply the chain succeeded.
      if (!result.succeeded) {
        final detail = (result.stderr ?? '').trim();
        ctx.output.warning(
          'The bootstrap command "$bootstrap" exited with code '
          '${result.exitCode} and may not have completed.'
          '${detail.isEmpty ? '' : '\n$detail'}',
        );
        _emitBootstrapHint(ctx, bootstrap: bootstrap, skipped: false);
      }
    } catch (e) {
      ctx.output.warning('Could not auto-run the bootstrap command: $e');
      _emitBootstrapHint(ctx, bootstrap: bootstrap, skipped: false);
    }
  }

  /// Builds the [BootstrapCommandRunner] used to spawn the chained bootstrap
  /// command. Test subclasses override to inject a recording fake so no real
  /// subprocess spawns during unit tests.
  ///
  /// @return A production [BootstrapCommandRunner] wired to [Process.run].
  @visibleForTesting
  BootstrapCommandRunner buildBootstrapRunner() => BootstrapCommandRunner();

  /// Convention-based registration of the plugin's [DowelServiceProvider] in
  /// `.dowel/plugins.json`, then a synchronous regeneration of
  /// `lib/app/_plugins.g.dart` via [PluginsRefreshCommand] so the host's
  /// `bin/dispatcher.dart` wrapper picks up the plugin's commands on the
  /// next invocation.
  ///
  /// Naming convention: `package:<name>/cli.dart` is the import URI and
  /// `<PascalCaseName>DowelProvider` is the class name. Plugins that follow
  /// a different convention are out of scope here; they can run
  /// `plugins:refresh` manually after editing `.dowel/plugins.json` by hand.
  ///
  /// @return `true` when the entry was recorded and the barrel regenerated;
  ///         `false` after a warning when either step failed.
  Future<bool> _registerDowelProvider(
    DowelContext ctx, {
    required String name,
  }) async {
    final root = getProjectRoot();
    final pascalName = _pascalCase(name);
    final entry = PluginEntry(
      name: name,
      providerImport: 'package:$name/cli.dart',
      providerClass: '${pascalName}DowelProvider',
      registeredAt: DateTime.now().toUtc().toIso8601String(),
    );

    try {
      await PluginsRegistryFile(const RealFs(), root).addPlugin(entry);
      final refreshed = await PluginsRefreshCommand(projectRoot: root)
          .handle(ctx);
      return refreshed == 0;
    } catch (e) {
      ctx.output.warning(
        'Plugin "$name" was installed but dowel command auto-registration '
        'failed: $e. Run `dart run dowel plugins:refresh` manually.',
      );
      return false;
    }
  }

  /// Maps a [TransactionResult] to the appropriate user-facing output +
  /// process exit code.
  int _renderResultAndExit(DowelContext ctx, TransactionResult result) {
    switch (result) {
      case InstallSuccess():
        ctx.output.success(result.describe());
        return 0;
      case InstallDryRun():
        ctx.output.info(result.describe());
        return 0;
      case InstallConflict():
        ctx.output.error(result.describe());
        return 2;
      case InstallError():
        ctx.output.error(result.describe());
        return 1;
    }
  }

  /// Emits the one-line bootstrap hint as the FALLBACK path for the manifest
  /// flow: when the operator passed `--no-bootstrap` ([skipped] true), or when
  /// auto-run could not resolve a dispatcher ([skipped] false). The happy path
  /// auto-runs the command instead via [_runBootstrapCommand].
  ///
  /// @param ctx        The active context.
  /// @param bootstrap  The resolved bootstrap command name.
  /// @param skipped    `true` when emitted because `--no-bootstrap` was set.
  void _emitBootstrapHint(
    DowelContext ctx, {
    required String bootstrap,
    required bool skipped,
  }) {
    if (skipped) {
      ctx.output.info('Skipping plugin bootstrap command (--no-bootstrap).');
    }
    ctx.output.info(
      'Re-run `dowel list` to see new commands. '
      'Bootstrap with: dowel $bootstrap',
    );
  }

  /// snake_case → PascalCase. `magic_logger` → `MagicLogger`.
  static String _pascalCase(String snake) {
    return snake
        .split('_')
        .where((part) => part.isNotEmpty)
        .map(StringHelper.toPascalCase)
        .join();
  }
}

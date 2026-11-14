import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../console/dowel_command.dart';
import '../console/dowel_context.dart';
import '../console/command_boot.dart';
import 'helpers/artisan_leftovers.dart';

/// Advisory warning emitted when `.mcp.json` still references the removed
/// `fluttersdk_mcp` package. Those entries live under the `fluttersdk` key,
/// which `mcp:install` no longer writes, so the user deletes the old entry
/// first. [key] is the entry's server name, usually `fluttersdk`.
String _staleMcpWarning(String key) =>
    'WARN: Stale MCP entry detected. Pre-upgrade .mcp.json points at the '
    'removed fluttersdk_mcp package. Delete the "$key" entry from '
    '.mcp.json, then run: ./bin/dowel mcp:install (or: '
    'dart run dowel mcp:install).';

/// Advisory warning emitted when `.mcp.json` still uses the pre-Bug-B
/// `fluttersdk_artisan:mcp` args shape. That shape routes through the substrate
/// standalone, which never loads consumer plugin providers. It lives under the
/// `fluttersdk` key as well, so the user deletes it before `mcp:install`
/// writes the branched entry shape under `dowel`. [key] is the entry's server
/// name, usually `fluttersdk`.
String _preFixMcpWarning(String key) =>
    'WARN: Pre-fix MCP entry detected. Your .mcp.json still uses the '
    'fluttersdk_artisan:mcp args shape from before Bug B was fixed. '
    'Delete the "$key" entry from .mcp.json, then run: '
    './bin/dowel mcp:install (or: dart run dowel mcp:install).';

/// Advisory warning emitted when `.mcp.json` still has the `fluttersdk` server
/// key that fluttersdk_artisan's `mcp:install` wrote, whatever its args:
/// `./bin/fsa mcp:serve` and `dart run :dispatcher mcp:serve` name no removed
/// package, so only the key gives them away. `mcp:install` writes `dowel` next
/// to it instead of replacing it.
const _oldKeyMcpWarning =
    'WARN: Old MCP entry detected. Your .mcp.json still has the "fluttersdk" '
    'server that fluttersdk_artisan wrote, and that package no longer exists. '
    'Delete the "fluttersdk" entry from .mcp.json, then run: '
    './bin/dowel mcp:install (or: dart run dowel mcp:install).';

/// Minimum Flutter SDK version required for the WebSocket hot reload fix that
/// enables CDP commands (flutter/flutter#170612).
const _minSdkVersion = '3.30.0';

/// Advisory warning emitted when the detected Flutter SDK is older than
/// [_minSdkVersion]. Instructs the user to run `flutter upgrade`.
const _cdpUpgradeWarning =
    'WARN: Flutter SDK is older than $_minSdkVersion. CDP commands '
    '(tapir:resize, tapir:device, dowel start --cdp-port) require the '
    'WebSocket hot reload fix from flutter/flutter#170612. '
    'Run `flutter upgrade` and re-check.';

/// Runs environment preflight checks (dowel toolchain).
class DoctorCommand extends DowelCommand {
  /// Creates a [DoctorCommand].
  ///
  /// [workingDir] pins the directory used for `.mcp.json` detection. Defaults
  /// to [Directory.current.path] when omitted. Inject a temp directory in
  /// tests to avoid depending on the real working directory.
  DoctorCommand({String? workingDir}) : _workingDir = workingDir;

  /// Pinned working directory for `.mcp.json` lookup.
  ///
  /// `null` means "use [Directory.current.path] at call time", which is the
  /// correct production behaviour (the cwd may change between construction and
  /// [handle]).
  final String? _workingDir;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Run environment preflight checks (flutter, dart, port availability).';

  @override
  CommandBoot get boot => CommandBoot.none;

  /// Test seam: swap this to inject a fake [ProcessResult] in unit tests.
  ///
  /// Production code keeps the default ([Process.run]). Tests replace it with
  /// a closure that returns a pre-built [ProcessResult] without spawning a
  /// real process.
  @visibleForTesting
  static Future<ProcessResult> Function(String, List<String>)
      doctorFlutterRunner = Process.run;

  /// Exposes [_cdpUpgradeWarning] for assertion in unit tests.
  @visibleForTesting
  static String get cdpUpgradeWarningForTest => _cdpUpgradeWarning;

  /// Exposes [_checkFlutterSdkVersion] for direct invocation in unit tests.
  @visibleForTesting
  static Future<bool> checkFlutterSdkVersionForTest() =>
      _checkFlutterSdkVersion();

  @override
  Future<int> handle(DowelContext ctx) async {
    // 1. Run hard preflight checks.
    final checks = <_Check>[
      _Check('flutter --version', _checkFlutter),
      _Check('dart --version', _checkDart),
      _Check('port 3100 free', _checkPort3100),
      _Check(
        'flutter sdk >= $_minSdkVersion (for --cdp-port)',
        _checkFlutterSdkVersion,
      ),
    ];
    var allPass = true;
    for (final c in checks) {
      final pass = await c.run();
      if (!pass) allPass = false;
      ctx.output.writeln('  ${pass ? '✓' : '✗'} ${c.label}');
    }

    // 2. Advisory: warn if .mcp.json still targets the removed fluttersdk_mcp.
    final dir = _workingDir ?? Directory.current.path;
    _checkStaleMcpJson(dir, ctx);

    // 3. Advisory: warn about files fluttersdk_artisan left behind.
    _checkArtisanLeftovers(dir, ctx);

    // 4. Advisory: warn when Flutter SDK is too old for CDP commands.
    await _checkCdpReadiness(ctx);

    return allPass ? 0 : 1;
  }

  /// Warns with the migration steps when [dir] still holds files from
  /// fluttersdk_artisan: a project renamed by hand keeps an old dispatcher
  /// that no longer compiles, and every command delegated to it fails with a
  /// compiler error instead of saying why. Advisory only.
  static void _checkArtisanLeftovers(String dir, DowelContext ctx) {
    final leftovers = artisanLeftovers(dir);
    if (leftovers.isEmpty) return;

    ctx.output.writeln(
      'WARN: fluttersdk_artisan leftovers. ${artisanMigrationSteps(leftovers)}',
    );
  }

  /// Checks whether `.mcp.json` in [dir] contains a stale or pre-fix
  /// `mcpServers` entry. Emits [_staleMcpWarning] when `fluttersdk_mcp:server`
  /// appears in any entry's args (legacy removed-package shape), or emits
  /// [_preFixMcpWarning] when `fluttersdk_artisan:mcp` appears (the pre-Bug-B
  /// substrate-standalone shape that never loads consumer plugin providers),
  /// or [_oldKeyMcpWarning] when only the `fluttersdk` server key gives an
  /// entry away. Does nothing when the file is absent or cannot be parsed.
  /// This is advisory only and never influences the exit code.
  static void _checkStaleMcpJson(String dir, DowelContext ctx) {
    final file = File('$dir/.mcp.json');
    if (!file.existsSync()) return;

    final Map<String, dynamic> root;
    try {
      root = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      // Malformed JSON: skip silently; not our job to validate the schema.
      return;
    }

    final servers = root['mcpServers'];
    if (servers is! Map<String, dynamic>) return;

    // 1. Scan all server entries for the legacy fluttersdk_mcp:server shape
    //    (the removed package from before the dowel absorption).
    for (final server in servers.entries) {
      final entry = server.value;
      if (entry is! Map<String, dynamic>) continue;
      final args = entry['args'];
      if (args is! List<dynamic>) continue;
      if (args.contains('fluttersdk_mcp:server')) {
        ctx.output.writeln(_staleMcpWarning(server.key));
        return;
      }
    }

    // 2. Scan all server entries for the pre-Bug-B fluttersdk_artisan:mcp shape
    //    (routes through the substrate standalone, which never loads consumer
    //    plugin providers; upgrading via mcp:install writes the correct shape).
    for (final server in servers.entries) {
      final entry = server.value;
      if (entry is! Map<String, dynamic>) continue;
      final args = entry['args'];
      if (args is! List<dynamic>) continue;
      if (args.contains('fluttersdk_artisan:mcp')) {
        ctx.output.writeln(_preFixMcpWarning(server.key));
        return;
      }
    }

    // 3. The fluttersdk key itself: the entries written by fluttersdk_artisan
    //    0.0.20 used `./bin/fsa mcp:serve` or `dart run :dispatcher
    //    mcp:serve`, which the two scans above cannot tell from a current one.
    if (servers.containsKey('fluttersdk')) {
      ctx.output.writeln(_oldKeyMcpWarning);
    }
  }

  /// Emits [_cdpUpgradeWarning] to [ctx] when [_checkFlutterSdkVersion]
  /// returns false. Advisory only; never influences the exit code.
  static Future<void> _checkCdpReadiness(DowelContext ctx) async {
    final sdkOk = await _checkFlutterSdkVersion();
    if (!sdkOk) {
      ctx.output.writeln(_cdpUpgradeWarning);
    }
  }

  /// Returns true when the installed Flutter SDK is at or above
  /// [_minSdkVersion], false otherwise.
  ///
  /// Runs `flutter --version --machine` and parses `frameworkVersion` from the
  /// JSON output. On parse failure or when `flutter` is not found, returns
  /// false so the check label surfaces the issue to the user.
  static Future<bool> _checkFlutterSdkVersion() async {
    try {
      final r = await doctorFlutterRunner('flutter', <String>[
        '--version',
        '--machine',
      ]);
      if (r.exitCode != 0) return false;

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      } catch (_) {
        return false;
      }

      final version = json['frameworkVersion'];
      if (version is! String) return false;

      return _isSdkVersionSufficient(version, _minSdkVersion);
    } catch (_) {
      return false;
    }
  }

  /// Compares two three-segment semver strings (e.g. "3.30.0") numerically.
  ///
  /// Returns true when [detected] is greater than or equal to [minimum].
  /// Malformed version strings (fewer than 3 segments or non-numeric segments)
  /// return false.
  static bool _isSdkVersionSufficient(String detected, String minimum) {
    final detectedParts = _parseVersion(detected);
    final minimumParts = _parseVersion(minimum);
    if (detectedParts == null || minimumParts == null) return false;

    for (var i = 0; i < 3; i++) {
      if (detectedParts[i] > minimumParts[i]) return true;
      if (detectedParts[i] < minimumParts[i]) return false;
    }
    return true; // equal
  }

  /// Parses a semver-ish string into a [major, minor, patch] integer list.
  /// Strips dev/build suffix (everything after the first `-`) to tolerate
  /// Flutter beta releases like `3.30.0-1.0.pre`, and pads missing trailing
  /// segments with 0 so `3.30` reads as `3.30.0`. Returns null when no
  /// numeric segments survive parsing.
  ///
  /// Kept in sync with `StartCommand.compareSemver` so the doctor SDK gate
  /// does not flag versions the start command would accept.
  static List<int>? _parseVersion(String version) {
    final core = version.split('-').first;
    final parts = core.split('.');
    if (parts.isEmpty) return null;
    final segments = <int>[
      for (var i = 0; i < 3; i++)
        if (i < parts.length) int.tryParse(parts[i]) ?? 0 else 0,
    ];
    if (segments.every((s) => s == 0) && core != '0.0.0') return null;
    return segments;
  }

  static Future<bool> _checkFlutter() async {
    try {
      final r = await Process.run('flutter', <String>['--version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _checkDart() async {
    try {
      final r = await Process.run('dart', <String>['--version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _checkPort3100() async {
    if (Platform.isWindows) return true; // skip for V1
    try {
      final r = await Process.run('lsof', <String>['-ti', 'tcp:3100']);
      return r.exitCode != 0 || (r.stdout as String).trim().isEmpty;
    } catch (_) {
      return true;
    }
  }
}

class _Check {
  _Check(this.label, this.run);
  final String label;
  final Future<bool> Function() run;
}

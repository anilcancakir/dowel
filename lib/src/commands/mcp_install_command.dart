import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../console/dowel_command.dart';
import '../console/dowel_context.dart';
import '../console/command_boot.dart';
import '../helpers/file_helper.dart';

/// `dowel mcp:install`: idempotently adds the dowel MCP server entry
/// to the project's `.mcp.json` (Claude Code / Cursor / Windsurf config).
///
/// Entry shape is chosen by a three-branch precedence rule. The first
/// branch only applies on POSIX hosts (macOS, Linux); Windows always
/// skips the `bin/dowel` shape because the shim is a POSIX shell script.
///
/// 1. POSIX host with `bin/dowel` present (fast path, ~110ms startup):
/// ```json
/// {
///   "mcpServers": {
///     "dowel": {
///       "command": "./bin/dowel",
///       "args": ["mcp:serve"],
///       "cwd": "."
///     }
///   }
/// }
/// ```
///
/// 2. POSIX without `bin/dowel`, or any Windows host, plus
/// `--invocation=<executable>` supplied (plugin executable path,
/// e.g. `tapir`, ~3s startup):
/// ```json
/// {
///   "mcpServers": {
///     "dowel": {
///       "command": "dart",
///       "args": ["run", "tapir", "mcp:serve"],
///       "cwd": "."
///     }
///   }
/// }
/// ```
///
/// 3. POSIX without `bin/dowel`, or any Windows host, without
/// `--invocation` (`:dispatcher` fallback, ~3s startup):
/// ```json
/// {
///   "mcpServers": {
///     "dowel": {
///       "command": "dart",
///       "args": ["run", ":dispatcher", "mcp:serve"],
///       "cwd": "."
///     }
///   }
/// }
/// ```
///
/// Pre-existing `mcpServers` keys are preserved. Running the command twice
/// replaces the `dowel` key in-place (idempotent; no duplicates).
///
/// After writing, the success line reminds the user that Claude Code does NOT
/// auto-reconnect on `.mcp.json` edits and must be told to do so manually.
class McpInstallCommand extends DowelCommand {
  /// Creates an [McpInstallCommand].
  ///
  /// [hasDowel] and [isWindows] are optional predicates injected for testing.
  /// Production callers omit both; tests pass custom closures to exercise
  /// each branch without touching the filesystem or reading `Platform`.
  McpInstallCommand({bool Function()? hasDowel, bool Function()? isWindows})
      : _hasDowel = hasDowel ?? _defaultHasDowel,
        _isWindows = isWindows ?? _defaultIsWindows;

  final bool Function() _hasDowel;
  final bool Function() _isWindows;

  static bool _defaultHasDowel() => FileHelper.fileExists('bin/dowel');
  static bool _defaultIsWindows() => Platform.isWindows;
  @override
  String get name => 'mcp:install';

  @override
  String get description => 'Add the dowel MCP server entry to .mcp.json '
      '(idempotent; preserves other server entries).';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  void configure(ArgParser parser) {
    parser.addOption(
      'path',
      defaultsTo: '.mcp.json',
      help: 'Path to the target .mcp.json file.',
    );
    parser.addOption(
      'invocation',
      help: 'Plugin executable name to write into .mcp.json command/args '
          'when fastcli is absent (e.g., tapir). Optional; falls back '
          'to the :dispatcher shape when omitted.',
    );
  }

  @override
  Future<int> handle(DowelContext ctx) async {
    final path = (ctx.input.option('path') as String?) ?? '.mcp.json';
    // Trim the raw value so a whitespace-only `--invocation="  "` collapses
    // to an empty string and falls through to the `:dispatcher` branch
    // rather than producing an invalid `dart run    mcp:serve` entry.
    final invocation = (ctx.input.option('invocation') as String?)?.trim();
    final file = File(path);

    // 1. Load existing config or start fresh.
    Map<String, dynamic> config;
    if (file.existsSync()) {
      try {
        config = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } catch (e) {
        ctx.output.error('Failed to parse $path: $e');
        return 1;
      }
    } else {
      config = <String, dynamic>{};
    }

    // 2. Merge the dowel entry into mcpServers using the appropriate
    //    payload shape: dowel fastcli, dart-run-invocation, or :dispatcher fallback.
    final servers = (config['mcpServers'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    final useDowel = _hasDowel() && !_isWindows();
    if (useDowel) {
      servers['dowel'] = <String, dynamic>{
        'command': './bin/dowel',
        'args': <String>['mcp:serve'],
        'cwd': '.',
      };
    } else if (invocation != null && invocation.isNotEmpty) {
      servers['dowel'] = <String, dynamic>{
        'command': 'dart',
        'args': <String>['run', invocation, 'mcp:serve'],
        'cwd': '.',
      };
    } else {
      servers['dowel'] = <String, dynamic>{
        'command': 'dart',
        'args': <String>['run', ':dispatcher', 'mcp:serve'],
        'cwd': '.',
      };
    }
    config['mcpServers'] = servers;

    // 3. Write atomically via `.tmp` + rename so concurrent MCP clients
    //    (Claude Code, Cursor, Windsurf) never observe a half-written
    //    `.mcp.json`. Mirrors the pattern used by StateFile.write and
    //    PluginsRegistryFile.write throughout this repo.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(config)}\n',
    );
    await tmp.rename(file.path);

    ctx.output.success(
      'Wrote dowel MCP server entry to $path.\n\n'
      'Note: Claude Code does NOT auto-reconnect on .mcp.json edits. '
      'Run /mcp reconnect dowel inside Claude Code to load the new entry.',
    );

    // 4. fluttersdk_artisan wrote its server under the `fluttersdk` key. It is
    //    the user's entry to delete, but left in place it runs a second server
    //    (or a dead one), so say so.
    if (servers.containsKey('fluttersdk')) {
      ctx.output.warning(
        'Delete the "fluttersdk" entry from $path: it was written by '
        'fluttersdk_artisan, which no longer exists, and runs next to the '
        'new dowel entry.',
      );
    }
    return 0;
  }
}

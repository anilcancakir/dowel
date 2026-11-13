import 'dart:convert';
import 'dart:io';

import 'package:dowel/dowel.dart';

/// `dowel mcp:uninstall` — remove the `dowel` MCP server entry from
/// `.mcp.json`. Handles both the legacy `fluttersdk_mcp:server` args shape and
/// the new `fluttersdk_artisan:mcp` args shape; the key name is `dowel`
/// in both cases. Preserves all other entries. Idempotent.
class McpUninstallCommand extends DowelCommand {
  @override
  String get name => 'mcp:uninstall';

  @override
  String get description =>
      'Remove the dowel MCP server entry from .mcp.json (preserves other entries).';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  void configure(ArgParser parser) {
    parser.addOption(
      'path',
      help: 'Path to the .mcp.json file.',
      defaultsTo: '.mcp.json',
    );
  }

  @override
  Future<int> handle(DowelContext ctx) async {
    final path = (ctx.input.option('path') as String?) ?? '.mcp.json';
    final file = File(path);

    // 1. Guard: file must exist; warn and exit cleanly when absent.
    if (!file.existsSync()) {
      ctx.output.warning('$path does not exist; nothing to uninstall.');
      return 0;
    }

    // 2. Parse the existing JSON content.
    final Map<String, dynamic> config;
    try {
      config = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } on FormatException catch (e) {
      ctx.output.error('$path contains invalid JSON: $e');
      return 1;
    }

    final servers = (config['mcpServers'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};

    // 3. Guard: warn and exit cleanly when the entry is already absent
    //    (handles both the idempotent second-run case and the never-installed
    //    case).
    if (!servers.containsKey('dowel')) {
      ctx.output.warning(
        'dowel entry not present in $path; nothing to uninstall.',
      );
      return 0;
    }

    // 4. Remove the entry and persist the updated config.
    servers.remove('dowel');
    config['mcpServers'] = servers;
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(config)}\n',
    );

    ctx.output.success('Removed dowel MCP server entry from $path.');
    return 0;
  }
}

import 'dart:io';

import 'package:dowel/dowel.dart';

/// Injectable typedef matching the [runDowel] signature used by [mcpMain].
///
/// Tests inject a recording closure; production callers leave [runDowel] at
/// its default ([runDowel] from the barrel) so the full dowel bootstrap
/// (builtin registration, provider walk, MCP tool collection) runs unmodified.
typedef RunDowelFn = Future<int> Function(
  List<String> args, {
  bool collectMcpTools,
  bool delegateToConsumer,
});

/// Testable entry point for the MCP server binary.
///
/// Prepends `mcp:serve` to [args] so that [runDowel] dispatches to
/// [McpServeCommand], forces [collectMcpTools] to `true` so every registered
/// provider's MCP tool descriptors are collected into the [DowelRegistry]
/// before the server starts, and forces `delegateToConsumer: false` so the
/// substrate's complete builtin list (including `mcp:serve`) owns dispatch:
/// the MCP entry NEVER delegates to a stale consumer wrapper
/// (`bin/dispatcher.dart`) that may be missing `mcp:*` commands. The MCP
/// server is the source of truth for its own dispatch surface.
///
/// [runDowel] is the injectable seam; production callers omit it and get
/// the real [runDowel] bootstrap from `package:dowel/dowel.dart`.
Future<int> mcpMain(List<String> args, {RunDowelFn? runDowel}) async {
  final fn = runDowel ?? _defaultRunDowel;
  return fn(
    ['mcp:serve', ...args],
    collectMcpTools: true,
    delegateToConsumer: false,
  );
}

/// Forwards to the real [runDowel] with positional + named args aligned.
Future<int> _defaultRunDowel(
  List<String> args, {
  bool collectMcpTools = false,
  bool delegateToConsumer = true,
}) => runDowel(
  args,
  collectMcpTools: collectMcpTools,
  delegateToConsumer: delegateToConsumer,
);

/// `dart run dowel:mcp [args]`: MCP server entry point.
///
/// Thin wrapper around [mcpMain]. All server logic lives in [McpServeCommand]
/// dispatched by [runDowel]; this file must not implement server logic
/// directly.
Future<void> main(List<String> args) async {
  stderr.writeln('[dowel_mcp] starting');
  exit(await mcpMain(args));
}

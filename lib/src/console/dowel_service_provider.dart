import '../mcp/mcp_tool_descriptor.dart';
import 'dowel_command.dart';

/// Base for any package that contributes commands to an [DowelApplication].
///
/// Magic-style ServiceProvider semantics: each provider returns the list of
/// commands it ships; [DowelRegistry] merges them under fail-fast
/// collision rules. Discovery is explicit (host app lists providers in
/// `appConfig['dowel']['providers']`, mirroring magic's existing
/// `app.providers` pattern).
abstract class DowelServiceProvider {
  /// Human-readable provider name (used in collision error messages).
  /// Defaults to the runtime class name.
  String get providerName => runtimeType.toString();

  /// Returns the commands this provider contributes to the application.
  List<DowelCommand> commands();

  /// Returns the MCP tool descriptors this provider contributes.
  ///
  /// Defaults to an empty list so existing providers compile without
  /// modification. Override to expose VM-Service-backed tools to the MCP
  /// server (see [McpToolDescriptor] for the descriptor contract).
  List<McpToolDescriptor> mcpTools() => const <McpToolDescriptor>[];
}

import 'package:test/test.dart';

import 'package:dowel/src/mcp/mcp_tool_collision_exception.dart';

void main() {
  group('DowelMcpToolCollisionException', () {
    const toolName = 'tapir_tap';
    const existingProvider = 'TapirProvider';
    const newProvider = 'MyPlugin';

    late DowelMcpToolCollisionException exception;

    setUp(() {
      exception = DowelMcpToolCollisionException(
        toolName: toolName,
        existingProvider: existingProvider,
        newProvider: newProvider,
      );
    });

    test('constructor populates all three fields', () {
      expect(exception.toolName, toolName);
      expect(exception.existingProvider, existingProvider);
      expect(exception.newProvider, newProvider);
    });

    test('implements Exception', () {
      expect(exception, isA<Exception>());
    });

    test('toString produces the canonical diagnostic message', () {
      final result = exception.toString();

      expect(
        result,
        'MCP tool collision: $toolName already registered by $existingProvider; '
        'cannot also register from $newProvider',
      );
    });

    test('toString embeds all three field values', () {
      final result = exception.toString();

      expect(result, contains(toolName));
      expect(result, contains(existingProvider));
      expect(result, contains(newProvider));
    });
  });
}

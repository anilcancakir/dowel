import 'package:dowel/dowel.dart';
import 'package:test/test.dart';

void main() {
  group('DowelRegistry MCP tool collection', () {
    test(
        'registerMcpToolsFor with a single provider exposing two unique tools '
        'registers both into mcpTools', () {
      final registry = DowelRegistry();
      final provider = _FakeMcpProvider('tapir', const <McpToolDescriptor>[
        McpToolDescriptor(
          name: 'tapir_snap',
          description: 'Capture a semantics snapshot.',
          inputSchema: <String, dynamic>{'type': 'object'},
          extensionMethod: 'ext.tapir.snap',
        ),
        McpToolDescriptor(
          name: 'tapir_tap',
          description: 'Tap a widget by ref.',
          inputSchema: <String, dynamic>{'type': 'object'},
          extensionMethod: 'ext.tapir.tap',
        ),
      ]);

      registry.registerMcpToolsFor(provider);

      expect(registry.mcpTools, hasLength(2));
      expect(
        registry.mcpTools.map((t) => t.name).toList(),
        containsAll(<String>['tapir_snap', 'tapir_tap']),
      );
    });

    test(
        'registerMcpToolsFor throws DowelMcpToolCollisionException when two '
        'providers register the same tool name; toString names both providers',
        () {
      final registry = DowelRegistry();
      final first = _FakeMcpProvider('tapir', const <McpToolDescriptor>[
        McpToolDescriptor(
          name: 'shared_tool',
          description: 'first',
          inputSchema: <String, dynamic>{'type': 'object'},
          extensionMethod: 'ext.tapir.shared',
        ),
      ]);
      final second = _FakeMcpProvider('crumbs', const <McpToolDescriptor>[
        McpToolDescriptor(
          name: 'shared_tool',
          description: 'second',
          inputSchema: <String, dynamic>{'type': 'object'},
          extensionMethod: 'ext.crumbs.shared',
        ),
      ]);

      registry.registerMcpToolsFor(first);

      try {
        registry.registerMcpToolsFor(second);
        fail('expected DowelMcpToolCollisionException');
      } on DowelMcpToolCollisionException catch (e) {
        final msg = e.toString();
        expect(msg, contains('shared_tool'));
        expect(msg, contains('tapir'));
        expect(msg, contains('crumbs'));
      }
    });

    test(
        'registerMcpToolsFor is a clean no-op when the provider returns an '
        'empty mcpTools() list (default-empty providers stay safe)', () {
      final registry = DowelRegistry();
      final provider = _FakeMcpProvider('silent', const <McpToolDescriptor>[]);

      registry.registerMcpToolsFor(provider);

      expect(registry.mcpTools, isEmpty);
    });
  });
}

class _FakeMcpProvider extends DowelServiceProvider {
  _FakeMcpProvider(this._name, this._tools);
  final String _name;
  final List<McpToolDescriptor> _tools;

  @override
  String get providerName => _name;

  @override
  List<DowelCommand> commands() => const <DowelCommand>[];

  @override
  List<McpToolDescriptor> mcpTools() => _tools;
}

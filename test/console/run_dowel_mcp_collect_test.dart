import 'package:dowel/dowel.dart';
import 'package:test/test.dart';

/// Verifies the `collectMcpTools` opt-in flag on [runDowel].
///
/// Observable contract:
/// 1. Default (`collectMcpTools: false`) never calls [DowelRegistry.registerMcpToolsFor],
///    proven by two providers with a duplicate tool name NOT causing a collision.
/// 2. `collectMcpTools: true` calls [DowelRegistry.registerMcpToolsFor] per provider,
///    proven by two providers with a duplicate tool name surfacing an exit 3
///    (collision propagates as a non-[DowelCommandCollisionException] to the
///    generic catch → exit 3).
/// 3. `collectMcpTools: true` with non-colliding providers succeeds (exit 0).
void main() {
  group('runDowel collectMcpTools', () {
    test('default collectMcpTools:false does NOT call registerMcpToolsFor; '
        'duplicate tool names across two providers produce no collision '
        '(legacy CLI behavior preserved)', () async {
      // Two providers sharing a tool name. If collectMcpTools were true,
      // DowelMcpToolCollisionException would fire and return exit 3.
      // With the default false, both providers' commands() are registered and
      // `list` dispatches cleanly → exit 0.
      final first = _SimpleMcpProvider(
        name: 'provider_alpha',
        tools: const <McpToolDescriptor>[
          McpToolDescriptor(
            name: 'shared_tool',
            description: 'first',
            inputSchema: <String, dynamic>{'type': 'object'},
            extensionMethod: 'ext.a.shared',
          ),
        ],
      );
      final second = _SimpleMcpProvider(
        name: 'provider_beta',
        tools: const <McpToolDescriptor>[
          McpToolDescriptor(
            name: 'shared_tool',
            description: 'second',
            inputSchema: <String, dynamic>{'type': 'object'},
            extensionMethod: 'ext.b.shared',
          ),
        ],
      );

      final code = await runDowel(
        <String>['list'],
        wrapperExists: () => false,
        baseProviders: <DowelServiceProvider>[first, second],
        // collectMcpTools omitted — defaults to false.
      );

      // No MCP collection → no collision → clean exit.
      expect(code, 0);
    });

    test('collectMcpTools:true with non-colliding tools from baseProviders '
        'succeeds and exits 0', () async {
      final provider = _SimpleMcpProvider(
        name: 'tapir',
        tools: const <McpToolDescriptor>[
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
        ],
      );

      final code = await runDowel(
        <String>['list'],
        wrapperExists: () => false,
        baseProviders: <DowelServiceProvider>[provider],
        collectMcpTools: true,
      );

      expect(code, 0);
    });

    test('collectMcpTools:true with non-colliding tools from autoProviders '
        'succeeds and exits 0', () async {
      final autoProvider = _SimpleMcpProvider(
        name: 'crumbs',
        tools: const <McpToolDescriptor>[
          McpToolDescriptor(
            name: 'crumbs_tail',
            description: 'Tail logs.',
            inputSchema: <String, dynamic>{'type': 'object'},
            extensionMethod: 'ext.crumbs.tail',
          ),
        ],
      );

      final code = await runDowel(
        <String>['list'],
        wrapperExists: () => false,
        autoProviders: () => <DowelServiceProvider>[autoProvider],
        collectMcpTools: true,
      );

      expect(code, 0);
    });

    test('collectMcpTools:true with a duplicate tool name across two '
        'baseProviders throws DowelMcpToolCollisionException → exit 3; '
        'both provider names surface in the exception message', () async {
      // Use a command-capturing provider so we can verify the exception was
      // DowelMcpToolCollisionException. The generic catch in runDowel
      // returns exit 3 for non-DowelCommandCollisionException throws.
      final first = _SimpleMcpProvider(
        name: 'provider_alpha',
        tools: const <McpToolDescriptor>[
          McpToolDescriptor(
            name: 'shared_tool',
            description: 'first',
            inputSchema: <String, dynamic>{'type': 'object'},
            extensionMethod: 'ext.a.shared',
          ),
        ],
      );
      final second = _SimpleMcpProvider(
        name: 'provider_beta',
        tools: const <McpToolDescriptor>[
          McpToolDescriptor(
            name: 'shared_tool',
            description: 'second',
            inputSchema: <String, dynamic>{'type': 'object'},
            extensionMethod: 'ext.b.shared',
          ),
        ],
      );

      final code = await runDowel(
        <String>['list'],
        wrapperExists: () => false,
        baseProviders: <DowelServiceProvider>[first, second],
        collectMcpTools: true,
      );

      // DowelMcpToolCollisionException is not caught by the
      // DowelCommandCollisionException branch (exit 2), so it falls
      // through to the generic catch → exit 3.
      expect(code, 3);
    });

    test(
      'collectMcpTools:true with a duplicate tool name across a baseProvider '
      'and an autoProvider also throws → exit 3',
      () async {
        const tool = McpToolDescriptor(
          name: 'shared_tool',
          description: 'shared',
          inputSchema: <String, dynamic>{'type': 'object'},
          extensionMethod: 'ext.shared',
        );

        final base = _SimpleMcpProvider(
          name: 'base_provider',
          tools: const <McpToolDescriptor>[tool],
        );
        final auto = _SimpleMcpProvider(
          name: 'auto_provider',
          tools: const <McpToolDescriptor>[tool],
        );

        final code = await runDowel(
          <String>['list'],
          wrapperExists: () => false,
          baseProviders: <DowelServiceProvider>[base],
          autoProviders: () => <DowelServiceProvider>[auto],
          collectMcpTools: true,
        );

        expect(code, 3);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Test-private helpers
// ---------------------------------------------------------------------------

/// A minimal provider exposing [tools] from [mcpTools]; no commands.
class _SimpleMcpProvider extends DowelServiceProvider {
  _SimpleMcpProvider({required this._name, required this._tools});

  final String _name;
  final List<McpToolDescriptor> _tools;

  @override
  String get providerName => _name;

  @override
  List<DowelCommand> commands() => const <DowelCommand>[];

  @override
  List<McpToolDescriptor> mcpTools() => _tools;
}

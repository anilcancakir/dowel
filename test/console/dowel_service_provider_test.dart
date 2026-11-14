import 'package:dowel/dowel.dart';
import 'package:test/test.dart';

void main() {
  group('DowelServiceProvider', () {
    test('default providerName equals the runtime class name', () {
      final provider = _UnnamedProvider();

      expect(provider.providerName, '_UnnamedProvider');
    });

    test('commands() returns the supplied list', () {
      final provider = _NamedProvider('demo', <DowelCommand>[
        _StubCommand('one'),
        _StubCommand('two'),
      ]);

      expect(provider.commands(), hasLength(2));
      expect(provider.providerName, 'demo');
    });

    test('plays nicely with DowelRegistry.registerProvider', () {
      final registry = DowelRegistry();
      final provider = _NamedProvider('p', <DowelCommand>[_StubCommand('one')]);

      registry.registerProvider(provider);

      expect(registry.find('one'), isNotNull);
    });

    test('returning [] is valid', () {
      final provider = _NamedProvider('empty', const <DowelCommand>[]);

      expect(provider.commands(), isEmpty);
    });

    test('mcpTools() defaults to an empty list', () {
      expect(_AnonymousProvider().mcpTools(), isEmpty);
    });
  });
}

/// Minimal provider with no overrides; exercises the default implementations.
class _AnonymousProvider extends DowelServiceProvider {
  @override
  List<DowelCommand> commands() => const <DowelCommand>[];
}

class _UnnamedProvider extends DowelServiceProvider {
  @override
  List<DowelCommand> commands() => const <DowelCommand>[];
}

class _NamedProvider extends DowelServiceProvider {
  _NamedProvider(this._name, this._commands);
  final String _name;
  final List<DowelCommand> _commands;

  @override
  String get providerName => _name;

  @override
  List<DowelCommand> commands() => _commands;
}

class _StubCommand extends DowelCommand {
  _StubCommand(this._name);
  final String _name;

  @override
  String get name => _name;

  @override
  String get description => 'stub $_name';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  Future<int> handle(DowelContext ctx) async => 0;
}

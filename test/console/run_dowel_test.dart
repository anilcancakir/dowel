import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('runDowel delegation', () {
    test('delegates to consumer wrapper when the wrapper exists', () async {
      var delegateCalled = false;
      List<String>? receivedArgs;

      final code = await runDowel(
        <String>['list'],
        wrapperExists: () => true,
        delegate: (args) async {
          delegateCalled = true;
          receivedArgs = args;
          return 42;
        },
      );

      expect(delegateCalled, isTrue);
      // Delegate receives args with the :dispatcher token prepended so it can
      // resolve to bin/dispatcher.dart (canonical post-0.0.2 wrapper). The
      // user-supplied 'list' arg follows the prefix unchanged.
      expect(receivedArgs, equals(<String>[':dispatcher', 'list']));
      expect(code, 42);
    });

    test('skips delegation when consumer wrapper is absent', () async {
      var delegateCalled = false;

      final code = await runDowel(
        <String>['list'],
        wrapperExists: () => false,
        delegate: (args) async {
          delegateCalled = true;
          return 0;
        },
      );

      expect(delegateCalled, isFalse);
      // Standalone path dispatches `list` against the builtins; exit 0.
      expect(code, 0);
    });

    test('bypass list skips delegation for commands:refresh', () async {
      var delegateCalled = false;

      await runDowel(
        <String>['commands:refresh'],
        wrapperExists: () => true,
        delegate: (args) async {
          delegateCalled = true;
          return 0;
        },
        // Force the standalone branch to terminate without doing real work
        // by stubbing the dispatcher via a base provider that owns the name.
        baseProviders: <DowelServiceProvider>[
          _StubProvider(<DowelCommand>[_NoopCommand('commands:refresh')]),
        ],
      );

      expect(delegateCalled, isFalse);
    });

    test('bypass list skips delegation for plugins:refresh', () async {
      var delegateCalled = false;

      await runDowel(
        <String>['plugins:refresh'],
        wrapperExists: () => true,
        delegate: (args) async {
          delegateCalled = true;
          return 0;
        },
        baseProviders: <DowelServiceProvider>[
          _StubProvider(<DowelCommand>[_NoopCommand('plugins:refresh')]),
        ],
      );

      expect(delegateCalled, isFalse);
    });

    test('delegateToConsumer:false skips delegation regardless', () async {
      var delegateCalled = false;

      final code = await runDowel(
        <String>['list'],
        delegateToConsumer: false,
        wrapperExists: () => true,
        delegate: (args) async {
          delegateCalled = true;
          return 99;
        },
      );

      expect(delegateCalled, isFalse);
      expect(code, 0);
    });

    test('delegates when args list is empty and wrapper present', () async {
      // Empty args → standalone help would normally fire, but since the
      // consumer wrapper is the canonical surface, empty argv still routes
      // there so the wrapper renders its own help with full provider list.
      var delegateCalled = false;

      await runDowel(
        <String>[],
        wrapperExists: () => true,
        delegate: (args) async {
          delegateCalled = true;
          return 0;
        },
      );

      expect(delegateCalled, isTrue);
    });

    test(
      '_defaultDelegate args prepend :dispatcher, not :dowel',
      () async {
        // Regression guard: the consumer wrapper is bin/dispatcher.dart. The
        // delegate seam must forward the :dispatcher token so dart resolves
        // to that file, not to this package's own bin/dowel.dart.
        List<String>? captured;

        await runDowel(
          <String>['list'],
          wrapperExists: () => true,
          delegateToConsumer: true,
          delegate: (args) async {
            captured = args;
            return 0;
          },
        );

        expect(captured, isNotNull);
        expect(captured!.first, ':dispatcher');
      },
    );

    test(
      'a package that only ships its own bin/dowel.dart does not delegate',
      () async {
        // bin/dowel.dart is this package's entry point, not a consumer
        // wrapper. Treating it as one made dowel delegate to itself when
        // run from its own repository.
        final tempRoot = Directory.systemTemp.createTempSync('own_entry_');
        addTearDown(() {
          if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
        });
        Directory(p.join(tempRoot.path, 'bin')).createSync(recursive: true);
        File(
          p.join(tempRoot.path, 'bin', 'dowel.dart'),
        ).writeAsStringSync('void main() {}\n');

        var delegateCalled = false;

        final code = await runDowel(
          <String>['list'],
          wrapperName: () => defaultConsumerWrapperName(cwd: tempRoot.path),
          delegateToConsumer: true,
          delegate: (args) async {
            delegateCalled = true;
            return 0;
          },
        );

        expect(delegateCalled, isFalse);
        expect(code, 0);
      },
    );

    test(
      'no wrapper present skips delegation cleanly',
      () async {
        // When bin/dispatcher.dart does not exist, the wrapper-name resolver
        // returns null and auto-delegation falls through to the standalone
        // path (no delegate invocation).
        final tempRoot = Directory.systemTemp.createTempSync('no_wrapper_');
        addTearDown(() {
          if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
        });

        var delegateCalled = false;

        final code = await runDowel(
          <String>['list'],
          wrapperName: () => defaultConsumerWrapperName(cwd: tempRoot.path),
          delegateToConsumer: true,
          delegate: (args) async {
            delegateCalled = true;
            return 0;
          },
        );

        expect(delegateCalled, isFalse);
        expect(code, 0);
      },
    );
  });

  group('runDowel standalone', () {
    test('registers base providers alongside builtins', () async {
      final probe = _ProbeCommand('probe:base');
      final provider = _StubProvider(<DowelCommand>[probe]);

      final code = await runDowel(
        <String>['probe:base'],
        wrapperExists: () => false,
        baseProviders: <DowelServiceProvider>[provider],
      );

      expect(probe.calls, 1);
      expect(code, 0);
    });

    test('registers auto-discovered providers from the factory', () async {
      final probe = _ProbeCommand('probe:auto');

      final code = await runDowel(
        <String>['probe:auto'],
        wrapperExists: () => false,
        autoProviders: () => <DowelServiceProvider>[
          _StubProvider(<DowelCommand>[probe]),
        ],
      );

      expect(probe.calls, 1);
      expect(code, 0);
    });

    test('builtins always include list + refresh commands', () async {
      // `list` is a builtin — without it, this would exit 1 (unknown command).
      final code = await runDowel(
        <String>['list'],
        wrapperExists: () => false,
      );

      expect(code, 0);
    });
  });

  group('defaultConsumerWrapperExists', () {
    // The default wrapper-presence helper accepts bin/dispatcher.dart (emitted
    // by `dart run dowel install`) and nothing else.

    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('default_wrapper_');
      Directory(p.join(tempRoot.path, 'bin')).createSync(recursive: true);
    });

    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    test('returns true when bin/dispatcher.dart is present', () {
      File(p.join(tempRoot.path, 'bin', 'dispatcher.dart'))
          .writeAsStringSync('void main() {}\n');

      expect(defaultConsumerWrapperExists(cwd: tempRoot.path), isTrue);
    });

    test('returns false for a bin/dowel.dart entry point alone', () {
      File(p.join(tempRoot.path, 'bin', 'dowel.dart'))
          .writeAsStringSync('void main() {}\n');

      expect(defaultConsumerWrapperExists(cwd: tempRoot.path), isFalse);
    });

    test('returns false when no wrapper is present', () {
      expect(defaultConsumerWrapperExists(cwd: tempRoot.path), isFalse);
    });
  });

  group('runDowel failure modes', () {
    test('DowelCommandCollisionException returns exit 2', () async {
      // Same command name from two providers; registry throws on the
      // second `register()`.
      final collidingProvider = _StubProvider(
        <DowelCommand>[_NoopCommand('list')],
        providerName: 'colliding',
      );

      final code = await runDowel(
        <String>['list'],
        wrapperExists: () => false,
        baseProviders: <DowelServiceProvider>[collidingProvider],
      );

      expect(code, 2);
    });

    test('generic exception during registration returns exit 3', () async {
      final code = await runDowel(
        <String>['list'],
        wrapperExists: () => false,
        autoProviders: () => throw StateError('autoProviders blew up'),
      );

      expect(code, 3);
    });

    test('--state=<path> is consumed before dispatch and recorded', () async {
      // A global flag rather than a per-command option: every connected
      // command needs it and none of them owns it, so it must never reach
      // the command's own parser.
      addTearDown(() => StateFile.pathOverride = null);
      List<String>? receivedArgs;

      await runDowel(
        <String>['list', '--state=/tmp/named-session.json'],
        wrapperExists: () => true,
        delegate: (List<String> args) async {
          receivedArgs = args;
          return 0;
        },
      );

      expect(StateFile.pathOverride, equals('/tmp/named-session.json'));
      // Re-attached, not dropped: the delegate spawns a separate process,
      // so a static on this isolate would never reach the command that
      // actually runs.
      expect(
        receivedArgs,
        equals(<String>[
          ':dispatcher',
          '--state=/tmp/named-session.json',
          'list',
        ]),
      );
    });

    test('--state <path> in two tokens is consumed the same way', () async {
      addTearDown(() => StateFile.pathOverride = null);
      List<String>? receivedArgs;

      await runDowel(
        <String>['--state', '/tmp/spaced-session.json', 'list'],
        wrapperExists: () => true,
        delegate: (List<String> args) async {
          receivedArgs = args;
          return 0;
        },
      );

      expect(StateFile.pathOverride, equals('/tmp/spaced-session.json'));
      expect(
        receivedArgs,
        equals(<String>[
          ':dispatcher',
          '--state=/tmp/spaced-session.json',
          'list',
        ]),
      );
    });

    test('a trailing --state with no value is left for the parser', () async {
      // Swallowing it would turn a typo into a silent no-op; the arg parser
      // is the layer that reports an unknown flag.
      addTearDown(() => StateFile.pathOverride = null);
      List<String>? receivedArgs;

      await runDowel(
        <String>['list', '--state'],
        wrapperExists: () => true,
        delegate: (List<String> args) async {
          receivedArgs = args;
          return 0;
        },
      );

      expect(StateFile.pathOverride, isNull);
      expect(receivedArgs, equals(<String>[':dispatcher', 'list', '--state']));
    });
  });
}

class _StubProvider extends DowelServiceProvider {
  _StubProvider(this._commands, {String? providerName})
      : _providerName = providerName ?? 'stub';

  final List<DowelCommand> _commands;
  final String _providerName;

  @override
  String get providerName => _providerName;

  @override
  List<DowelCommand> commands() => _commands;
}

class _NoopCommand extends DowelCommand {
  _NoopCommand(this._name);
  final String _name;

  @override
  String get name => _name;

  @override
  String get description => 'noop';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  Future<int> handle(DowelContext ctx) async => 0;
}

class _ProbeCommand extends DowelCommand {
  _ProbeCommand(this._name);
  final String _name;
  int calls = 0;

  @override
  String get name => _name;

  @override
  String get description => 'probe';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  Future<int> handle(DowelContext ctx) async {
    calls++;
    return 0;
  }
}

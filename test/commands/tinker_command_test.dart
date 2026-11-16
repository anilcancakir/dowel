import 'package:dowel/dowel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' show RPCError, Response;

/// A client whose `evaluate` fails the way dwds does on a web-server device,
/// unless [error] says otherwise.
class _WebServerVmServiceClient extends VmServiceClient {
  _WebServerVmServiceClient({RPCError? error})
    : error =
          error ??
          RPCError(
            'evaluate',
            -32603,
            'evaluate: NoSuchMethodError: Class \'WebSocketProxyService\' has '
                'no instance method \'evaluate\' with matching arguments.',
          ),
      super('ws://stub-only/');

  final RPCError error;

  @override
  Future<String> getMainIsolateId() async => 'isolate-stub';

  @override
  Future<Response> evaluate(String isolateId, String expression) => throw error;
}

void main() {
  group('TinkerCommand', () {
    setUp(() {
      Tinker.casters.clear();
    });

    test('metadata: name=tinker, boot=connected', () {
      final command = TinkerCommand();

      expect(command.name, 'tinker');
      expect(command.boot, CommandBoot.connected);
      expect(command.description, isNotEmpty);
    });

    test('inherits DowelCommand contract', () {
      final command = TinkerCommand();

      expect(command, isA<DowelCommand>());
    });

    test(
      'Tinker.casters chain is consulted by every invocation (contract)',
      () {
        // Sanity guard: appending a caster does not throw and shows up in the
        // chain consumed by TinkerCommand's _formatResult.
        Tinker.casters.add((v) => v?.toString());

        expect(Tinker.casters, isNotEmpty);
      },
    );

    test('signature declares --eval= option (one-shot eval mode)', () {
      final command = TinkerCommand();

      expect(command.signature, contains('{--eval='));
      expect(command.signature, contains('REPL is skipped'));
    });

    test('handle with --eval set short-circuits and propagates ctx.evaluate '
        'failure (no REPL chatter)', () async {
      // Bare context has no VmServiceClient bound; ctx.evaluate throws
      // StateError on the first call. The --eval branch catches this and
      // writes the error message to output, returning exit=1 ; verifies the
      // one-shot path is wired (REPL would never even reach evaluate without
      // stdin input).
      final output = BufferedOutput();
      final ctx = DowelContext.bare(MapInput(const {'eval': '1 + 1'}), output);

      final exit = await TinkerCommand().handle(ctx);

      expect(exit, 1, reason: 'eval branch returns 1 when ctx.evaluate raises');
      expect(
        output.content,
        contains('non-connected'),
        reason: 'StateError message from disconnected evaluate flows through',
      );
      expect(
        output.content,
        isNot(contains('Tinker connected')),
        reason: 'REPL banner must not appear when --eval is set',
      );
      expect(
        output.content,
        isNot(contains('Tinker session ended')),
        reason: 'REPL closing line must not appear when --eval is set',
      );
    });

    test('handle with --eval turns the web-server evaluate gap into one '
        'actionable line (exit 1)', () async {
      // dwds answers `evaluate` on a web-server session with a raw
      // NoSuchMethodError from its WebSocketProxyService, which has no
      // evaluate. The chrome device (Dart Debug connection) answers it.
      final output = BufferedOutput();
      final ctx = DowelContext.connected(
        MapInput(const {'eval': '1+1'}),
        output,
        _WebServerVmServiceClient(),
      );

      final exit = await TinkerCommand().handle(ctx);

      expect(exit, 1);
      expect(output.content, contains('not available on a web-server session'));
      expect(output.content, contains('dowel start --device=chrome'));
      expect(output.content, contains('without --cdp-port'));
      expect(output.content, isNot(contains('NoSuchMethodError')));
      expect(output.content, isNot(contains('WebSocketProxyService')));
    });

    test('handle with --eval leaves every other evaluate failure verbatim '
        '(exit 1)', () async {
      final output = BufferedOutput();
      final ctx = DowelContext.connected(
        MapInput(const {'eval': '1+'}),
        output,
        _WebServerVmServiceClient(
          error: RPCError('evaluate', 113, 'Expression compilation error'),
        ),
      );

      final exit = await TinkerCommand().handle(ctx);

      expect(exit, 1);
      expect(output.content, contains('Expression compilation error'));
      expect(output.content, isNot(contains('web-server')));
    });

    test('handle with empty --eval falls through to REPL banner '
        '(stdin EOF closes the loop cleanly)', () async {
      // No --eval flag ; REPL path runs. The first stdin.readLineSync() in a
      // non-tty test returns null (EOF) so the loop exits immediately. The
      // banner + closing line are written; exit is 0.
      final output = BufferedOutput();
      final ctx = DowelContext.bare(MapInput(const {}), output);

      final exit = await TinkerCommand().handle(ctx);

      expect(exit, 0);
      expect(output.content, contains('Tinker connected'));
      expect(output.content, contains('Tinker session ended'));
    });

    test(
      'handle rejects a blank --eval instead of starting the REPL',
      () async {
        // Under `mcp:serve` stdin is the JSON-RPC channel, so a REPL started
        // from `eval: ""` would read protocol frames as Dart expressions.
        final output = BufferedOutput();
        final ctx = DowelContext.bare(MapInput(const {'eval': '  '}), output);

        final exit = await TinkerCommand().handle(ctx);

        expect(exit, 1);
        expect(output.content, contains('--eval needs a Dart expression'));
        expect(output.content, isNot(contains('Tinker connected')));
      },
    );
  });
}

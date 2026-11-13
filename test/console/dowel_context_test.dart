import 'package:dowel/dowel.dart';
import 'package:test/test.dart';

void main() {
  group('DowelContext.bare', () {
    test('exposes input and output', () {
      final input = MapInput(const {'k': 'v'});
      final output = BufferedOutput();

      final ctx = DowelContext.bare(input, output);

      expect(ctx.input, same(input));
      expect(ctx.output, same(output));
    });

    test('vmClient is null', () {
      final ctx = DowelContext.bare(MapInput(const {}), BufferedOutput());

      expect(ctx.vmClient, isNull);
    });

    test('callExtension throws StateError citing connected-mode requirement',
        () async {
      final ctx = DowelContext.bare(MapInput(const {}), BufferedOutput());

      expect(
        () => ctx.callExtension('ext.flutter.reassemble'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('CommandBoot.connected'),
          ),
        ),
      );
    });

    test('evaluate throws StateError citing connected-mode requirement',
        () async {
      final ctx = DowelContext.bare(MapInput(const {}), BufferedOutput());

      expect(
        () => ctx.evaluate('1 + 1'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('CommandBoot.connected'),
          ),
        ),
      );
    });
  });

  group('DowelContext.bare registry', () {
    test('registry is null when constructed without one', () {
      final ctx = DowelContext.bare(MapInput(const {}), BufferedOutput());

      expect(ctx.registry, isNull);
    });

    test('registry is non-null when supplied to bare constructor', () {
      final registry = DowelRegistry();
      final ctx = DowelContext.bare(
        MapInput(const {}),
        BufferedOutput(),
        registry: registry,
      );

      expect(ctx.registry, same(registry));
    });
  });

  group('DowelContext.connected', () {
    test('exposes the supplied VmServiceClient', () {
      final client = VmServiceClient('ws://example.invalid:1/ws');
      final ctx = DowelContext.connected(
        MapInput(const {}),
        BufferedOutput(),
        client,
      );

      expect(ctx.vmClient, same(client));
    });

    test('input and output forwarded to the connected ctx', () {
      final input = MapInput(const {});
      final output = BufferedOutput();
      final client = VmServiceClient('ws://example.invalid:1/ws');

      final ctx = DowelContext.connected(input, output, client);

      expect(ctx.input, same(input));
      expect(ctx.output, same(output));
    });

    test('registry is null when not supplied to connected constructor', () {
      final client = VmServiceClient('ws://example.invalid:1/ws');
      final ctx = DowelContext.connected(
        MapInput(const {}),
        BufferedOutput(),
        client,
      );

      expect(ctx.registry, isNull);
    });

    test('registry is non-null when supplied to connected constructor', () {
      final client = VmServiceClient('ws://example.invalid:1/ws');
      final registry = DowelRegistry();
      final ctx = DowelContext.connected(
        MapInput(const {}),
        BufferedOutput(),
        client,
        registry: registry,
      );

      expect(ctx.registry, same(registry));
    });
  });
}

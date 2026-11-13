import 'package:dowel/src/commands/helpers/dowel_path_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('DowelPathResolver.computeRelative', () {
    test(
      'nested case: target two levels deep → ../../dowel',
      () {
        const dowelRoot = '/foo/dowel';
        const targetDir = '/foo/example_magic/packages/x';

        final result = DowelPathResolver.computeRelative(
          dowelRoot: dowelRoot,
          targetDir: targetDir,
        );

        expect(result, equals('../../../dowel'));
      },
    );

    test(
      'deep nested case: target five levels deep → ../../../../../dowel',
      () {
        const dowelRoot = '/foo/dowel';
        const targetDir = '/foo/a/b/c/d/e';

        final result = DowelPathResolver.computeRelative(
          dowelRoot: dowelRoot,
          targetDir: targetDir,
        );

        expect(result, equals('../../../../../dowel'));
      },
    );

    test(
      'sibling case: target is sibling directory → ../dowel',
      () {
        const dowelRoot = '/foo/dowel';
        const targetDir = '/foo/my_plugin';

        final result = DowelPathResolver.computeRelative(
          dowelRoot: dowelRoot,
          targetDir: targetDir,
        );

        expect(result, equals('../dowel'));
      },
    );

    test(
      'identical dir: dowelRoot equals targetDir → .',
      () {
        const dowelRoot = '/foo/dowel';
        const targetDir = '/foo/dowel';

        final result = DowelPathResolver.computeRelative(
          dowelRoot: dowelRoot,
          targetDir: targetDir,
        );

        expect(result, equals('.'));
      },
    );
  });
}

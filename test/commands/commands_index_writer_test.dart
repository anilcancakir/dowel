import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dowel_index_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('discoverCommandsInDir', () {
    test('returns empty list for non-existent directory', () {
      final missing = Directory(p.join(tempDir.path, 'nope'));
      expect(discoverCommandsInDir(missing), isEmpty);
    });

    test('returns empty list for empty directory', () {
      expect(discoverCommandsInDir(tempDir), isEmpty);
    });

    test('detects a single command in a single file', () {
      File(p.join(tempDir.path, 'clean_cache.dart')).writeAsStringSync('''
import 'package:dowel/dowel.dart';
class CleanCacheCommand extends DowelCommand {
  @override
  String get name => 'clean:cache';
}
''');

      final got = discoverCommandsInDir(tempDir);

      expect(got, hasLength(1));
      expect(got.first.className, 'CleanCacheCommand');
      expect(got.first.fileName, 'clean_cache.dart');
    });

    test('detects multiple commands in the same file', () {
      File(p.join(tempDir.path, 'multi.dart')).writeAsStringSync('''
class FooCommand extends DowelCommand {}
class BarCommand extends DowelCommand {}
''');

      final got = discoverCommandsInDir(tempDir);

      expect(got.map((c) => c.className), ['FooCommand', 'BarCommand']);
      expect(got.every((c) => c.fileName == 'multi.dart'), isTrue);
    });

    test('detects across multiple files, sorted by file path', () {
      File(p.join(tempDir.path, 'zebra.dart')).writeAsStringSync(
        'class ZebraCommand extends DowelCommand {}',
      );
      File(p.join(tempDir.path, 'alpha.dart')).writeAsStringSync(
        'class AlphaCommand extends DowelCommand {}',
      );

      final got = discoverCommandsInDir(tempDir);

      expect(got.map((c) => c.fileName), ['alpha.dart', 'zebra.dart']);
    });

    test('skips _index.g.dart', () {
      File(p.join(tempDir.path, '_index.g.dart')).writeAsStringSync(
        'class IndexCommand extends DowelCommand {}',
      );
      File(p.join(tempDir.path, 'real.dart')).writeAsStringSync(
        'class RealCommand extends DowelCommand {}',
      );

      final got = discoverCommandsInDir(tempDir);

      expect(got.map((c) => c.className), ['RealCommand']);
    });

    test('skips any file whose name starts with underscore', () {
      File(p.join(tempDir.path, '_helper.dart')).writeAsStringSync(
        'class HiddenCommand extends DowelCommand {}',
      );
      File(p.join(tempDir.path, 'visible.dart')).writeAsStringSync(
        'class VisibleCommand extends DowelCommand {}',
      );

      final got = discoverCommandsInDir(tempDir);

      expect(got.map((c) => c.className), ['VisibleCommand']);
    });

    test('skips non-dart files', () {
      File(p.join(tempDir.path, 'README.md')).writeAsStringSync(
        'class GhostCommand extends DowelCommand {}',
      );

      expect(discoverCommandsInDir(tempDir), isEmpty);
    });

    test(
        'requires BOTH class name ending in Command AND base ending in Command',
        () {
      File(p.join(tempDir.path, 'mixed.dart')).writeAsStringSync('''
class GoodCommand extends DowelCommand {}
class NotACommand extends StatelessWidget {}
class AlsoMatchCommand extends MyCustomCommand {}
class NoSuffix extends DowelCommand {}
class AlsoNot extends SomeBase {}
''');

      final got = discoverCommandsInDir(tempDir);

      expect(
        got.map((c) => c.className),
        ['GoodCommand', 'AlsoMatchCommand'],
      );
    });

    test('matches both DowelCommand and DowelGeneratorCommand bases', () {
      File(p.join(tempDir.path, 'make.dart')).writeAsStringSync('''
class MakeFooCommand extends DowelGeneratorCommand {}
''');

      final got = discoverCommandsInDir(tempDir);
      expect(got.single.className, 'MakeFooCommand');
    });
  });

  group('renderCommandsIndex', () {
    test('renders empty-list shape when no commands', () {
      final out = renderCommandsIndex(const []);
      expect(out, contains("import 'package:dowel/dowel.dart'"));
      expect(
        out,
        contains(
          'List<DowelCommand> get commands => const <DowelCommand>[];',
        ),
      );
    });

    test('renders one import + one instantiation per file', () {
      final out = renderCommandsIndex(const [
        DiscoveredCommand(
          className: 'FooCommand',
          fileName: 'foo.dart',
        ),
      ]);
      expect(out, contains("import 'foo.dart';"));
      expect(out, contains('  FooCommand(),'));
    });

    test('deduplicates imports when a file has multiple commands', () {
      final out = renderCommandsIndex(const [
        DiscoveredCommand(className: 'FooCommand', fileName: 'multi.dart'),
        DiscoveredCommand(className: 'BarCommand', fileName: 'multi.dart'),
      ]);
      expect("'multi.dart'".allMatches(out).length, 1);
      expect(out, contains('  FooCommand(),'));
      expect(out, contains('  BarCommand(),'));
    });

    test('sorts imports alphabetically', () {
      final out = renderCommandsIndex(const [
        DiscoveredCommand(className: 'ZebraCommand', fileName: 'zebra.dart'),
        DiscoveredCommand(className: 'AlphaCommand', fileName: 'alpha.dart'),
      ]);
      final alphaIdx = out.indexOf("'alpha.dart'");
      final zebraIdx = out.indexOf("'zebra.dart'");
      expect(alphaIdx, lessThan(zebraIdx));
    });

    test('emits the AUTO-GENERATED header', () {
      final out = renderCommandsIndex(const []);
      expect(out, contains('AUTO-GENERATED'));
      expect(out, contains('commands:refresh'));
      expect(out, contains('make:command'));
    });
  });

  group('writeCommandsIndex', () {
    test('creates the directory if missing', () {
      final dir = Directory(p.join(tempDir.path, 'fresh'));
      expect(dir.existsSync(), isFalse);

      writeCommandsIndex(dir);

      expect(dir.existsSync(), isTrue);
      expect(File(p.join(dir.path, '_index.g.dart')).existsSync(), isTrue);
    });

    test('writes a valid empty-index file when no commands discovered', () {
      writeCommandsIndex(tempDir);
      final content =
          File(p.join(tempDir.path, '_index.g.dart')).readAsStringSync();
      expect(content, contains('const <DowelCommand>[]'));
    });

    test('overwrites prior content on each call', () {
      // First pass: one command.
      File(p.join(tempDir.path, 'one.dart'))
          .writeAsStringSync('class OneCommand extends DowelCommand {}');
      writeCommandsIndex(tempDir);
      var content =
          File(p.join(tempDir.path, '_index.g.dart')).readAsStringSync();
      expect(content, contains('OneCommand()'));

      // Second pass: command file deleted; index should reflect.
      File(p.join(tempDir.path, 'one.dart')).deleteSync();
      writeCommandsIndex(tempDir);
      content = File(p.join(tempDir.path, '_index.g.dart')).readAsStringSync();
      expect(content, isNot(contains('OneCommand')));
      expect(content, contains('const <DowelCommand>[]'));
    });

    test('returns the discovered list for caller reporting', () {
      File(p.join(tempDir.path, 'r.dart'))
          .writeAsStringSync('class RCommand extends DowelCommand {}');

      final got = writeCommandsIndex(tempDir);

      expect(got, hasLength(1));
      expect(got.single.className, 'RCommand');
    });
  });
}

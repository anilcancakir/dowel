import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('StubLoader.replace', () {
    test('substitutes a single placeholder', () {
      final out = StubLoader.replace('Hello {{ name }}', {'name': 'World'});
      expect(out, 'Hello World');
    });

    test('substitutes multiple placeholders', () {
      final out = StubLoader.replace(
        'class {{ className }} extends {{ baseClass }} {}',
        {'className': 'Monitor', 'baseClass': 'Model'},
      );
      expect(out, 'class Monitor extends Model {}');
    });

    test('substitutes the same placeholder appearing multiple times', () {
      final out = StubLoader.replace('{{ x }} and {{ x }} and {{ x }}', {
        'x': 'value',
      });
      expect(out, 'value and value and value');
    });

    test('leaves unknown placeholders untouched', () {
      final out = StubLoader.replace('{{ known }} {{ unknown }}', {
        'known': 'X',
      });
      expect(out, 'X {{ unknown }}');
    });

    test('returns the input verbatim when no replacements supplied', () {
      const input = 'no placeholders here';
      expect(StubLoader.replace(input, const {}), input);
    });
  });

  group('StubLoader.load', () {
    late Directory tempDir;
    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dowel_stub_test_');
      File('${tempDir.path}/widget.stub')
          .writeAsStringSync('Widget body for {{ className }}.');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('reads a stub file via custom searchPaths', () {
      final content = StubLoader.load('widget', searchPaths: [tempDir.path]);
      expect(content, 'Widget body for {{ className }}.');
    });

    test('throws FileSystemException when stub missing', () {
      expect(
        () => StubLoader.load('nope', searchPaths: [tempDir.path]),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('walks searchPaths in order, returning the first hit', () {
      final secondDir = Directory.systemTemp.createTempSync('dowel_second_');
      addTearDown(() => secondDir.deleteSync(recursive: true));
      File('${secondDir.path}/widget.stub')
          .writeAsStringSync('SECOND wins (should not be returned)');

      // tempDir listed FIRST → its stub wins.
      final content = StubLoader.load(
        'widget',
        searchPaths: [tempDir.path, secondDir.path],
      );

      expect(content, contains('Widget body for'));
      expect(content, isNot(contains('SECOND wins')));
    });
  });

  group('StubLoader.make', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dowel_make_test_');
      File('${tempDir.path}/greet.stub')
          .writeAsStringSync('Hello, {{ subject }}!');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('load + replace in one call', () {
      // make() uses the default search paths, so we test via load+replace
      // (the helper is a thin convenience over the two).
      final content = StubLoader.load('greet', searchPaths: [tempDir.path]);
      final out = StubLoader.replace(content, {'subject': 'World'});
      expect(out, 'Hello, World!');
    });
  });

  group('StubLoader default search paths (package_config resolver)', () {
    test('load via default paths resolves the dispatcher stub', () {
      // No searchPaths arg → exercises _defaultSearchPaths +
      // _resolveFromPackageConfig. The package_config.json sitting at the
      // package root names dowel, so the resolver returns a
      // valid stub dir.
      final content = StubLoader.load('dispatcher.dart');

      expect(content, contains('{{ name }}'));
    });

    test('make composes load + replace via default search paths', () {
      // The loader treats the replacement map as literal substitution; this
      // mirrors how `install` renders the bin/dispatcher.dart wrapper.
      final content = StubLoader.make('dispatcher.dart', <String, String>{
        'name': 'my_app',
      });

      expect(content, contains('my_app'));
    });

    test(
      'load resolves after package name const extraction (regression test)',
      () {
        // Verify that extracting 'dowel' hardcoded strings to
        // a const does not break stub resolution. This test exercises both
        // package_config.json parsing (line 157) and pubspec walking (line 107)
        // which reference the package name.
        final content = StubLoader.load('dispatcher.dart');

        // If the const extraction broke either path, this would throw
        // FileSystemException. Confirming it returns valid content.
        expect(content, isNotEmpty);
        expect(content, contains('{{ name }}'));
      },
    );

    test('decodes a percent-encoded rootUri with a trailing slash', () {
      // pub writes a relative rootUri percent-encoded. Joined as a plain path
      // it named `plug%20%C4%B1`, which does not exist, and the loader fell
      // through to whatever dowel the running script came from.
      final root = Directory.systemTemp.createTempSync('stub_loader_uri_');
      final previous = Directory.current;
      addTearDown(() {
        Directory.current = previous;
        root.deleteSync(recursive: true);
      });
      final project = Directory(p.join(root.path, 'proj'))..createSync();
      File(p.join(project.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '{"configVersion": 2, "packages": [{"name": "dowel", '
          '"rootUri": "../../plug%20%C4%B1/", "packageUri": "lib/"}]}',
        );
      File(p.join(root.path, 'plug ı', 'assets', 'stubs', 'probe.stub'))
        ..createSync(recursive: true)
        ..writeAsStringSync('from the encoded root');
      Directory.current = project;

      expect(StubLoader.load('probe'), 'from the encoded root');
    });

    test('dispatcher stub forwards collectMcpTools to runDowel', () {
      // The stub must pass collectMcpTools so plugin providers collect their
      // MCP tool descriptors when the consumer invokes mcp:serve. Without
      // this arg, runDowel's split-API never calls registerMcpToolsFor and
      // tools/list returns an empty array (GitHub issue #7, Bug A).
      final content = StubLoader.load('dispatcher.dart');

      expect(content, contains('collectMcpTools'));
    });
  });
}

import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ConfigEditor', () {
    late Directory tempDir;
    late String pubspecPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dowel_cfg_editor_');
      pubspecPath = p.join(tempDir.path, 'pubspec.yaml');
      File(pubspecPath).writeAsStringSync(
        'name: host_app\nversion: 1.0.0\n\ndependencies:\n  meta: ^1.0.0\n',
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('addDependencyToPubspec adds a new dependency', () {
      ConfigEditor.addDependencyToPubspec(
        pubspecPath: pubspecPath,
        name: 'http',
        version: '^1.0.0',
      );

      final content = File(pubspecPath).readAsStringSync();
      expect(content, contains('http: ^1.0.0'));
    });

    test('addDependencyToPubspec updates an existing dependency', () {
      ConfigEditor.addDependencyToPubspec(
        pubspecPath: pubspecPath,
        name: 'meta',
        version: '^1.16.0',
      );

      final content = File(pubspecPath).readAsStringSync();
      expect(content, contains('meta: ^1.16.0'));
    });

    test('addPathDependencyToPubspec writes the path-style dependency', () {
      ConfigEditor.addPathDependencyToPubspec(
        pubspecPath: pubspecPath,
        name: 'local_plugin',
        path: './plugins/local_plugin',
      );

      final content = File(pubspecPath).readAsStringSync();
      expect(content, contains('local_plugin'));
      expect(content, contains('./plugins/local_plugin'));
    });

    test('removeDependencyFromPubspec deletes the entry', () {
      ConfigEditor.removeDependencyFromPubspec(
        pubspecPath: pubspecPath,
        name: 'meta',
      );

      final content = File(pubspecPath).readAsStringSync();
      expect(content, isNot(contains('meta:')));
    });

    test('removeDependencyFromPubspec is a no-op for unknown dependency', () {
      final before = File(pubspecPath).readAsStringSync();

      ConfigEditor.removeDependencyFromPubspec(
        pubspecPath: pubspecPath,
        name: 'not_present',
      );

      expect(File(pubspecPath).readAsStringSync(), before);
    });

    test('updatePubspecValue creates nested keys when missing', () {
      ConfigEditor.updatePubspecValue(
        pubspecPath: pubspecPath,
        keyPath: <String>['environment', 'sdk'],
        value: '>=3.4.0 <4.0.0',
      );

      final content = File(pubspecPath).readAsStringSync();
      expect(content, contains('environment:'));
      expect(content, contains('sdk:'));
    });

    test('addImportToFile injects after existing imports, idempotent', () {
      final dartPath = p.join(tempDir.path, 'main.dart');
      File(dartPath).writeAsStringSync(
        "import 'package:meta/meta.dart';\n\nvoid main() {}\n",
      );

      ConfigEditor.addImportToFile(
        filePath: dartPath,
        importStatement: "import 'package:http/http.dart'",
      );

      var content = File(dartPath).readAsStringSync();
      expect(content, contains("import 'package:http/http.dart';"));

      // Second call is a no-op.
      ConfigEditor.addImportToFile(
        filePath: dartPath,
        importStatement: "import 'package:http/http.dart';",
      );

      content = File(dartPath).readAsStringSync();
      final count = 'http/http.dart'.allMatches(content).length;
      expect(count, 1);
    });

    group('addImportToFile directive boundaries', () {
      late String dartPath;

      setUp(() {
        dartPath = p.join(tempDir.path, 'main.dart');
      });

      /// Seeds [source], adds each of [statements] in turn and returns the file.
      String addImports(String source, List<String> statements) {
        File(dartPath).writeAsStringSync(source);
        for (final statement in statements) {
          ConfigEditor.addImportToFile(
            filePath: dartPath,
            importStatement: statement,
          );
        }

        return File(dartPath).readAsStringSync();
      }

      test('inserts after a multi-line show directive, not inside it', () {
        final content = addImports(
          "import 'package:a/a.dart'\n    show A;\n\nvoid main() {}\n",
          ["import 'package:b/b.dart';"],
        );

        expect(
          content,
          "import 'package:a/a.dart'\n"
          '    show A;\n'
          "import 'package:b/b.dart';\n"
          '\n'
          'void main() {}\n',
        );
      });

      test('inserts after the last of several multi-line directives', () {
        final content = addImports(
          "import 'package:a/a.dart'\n"
          '    show A;\n'
          "import 'package:c/c.dart';\n"
          "import 'package:d/d.dart'\n"
          '    hide D;\n'
          '\n'
          'void main() {}\n',
          ["import 'package:b/b.dart';"],
        );

        expect(
          content,
          "import 'package:a/a.dart'\n"
          '    show A;\n'
          "import 'package:c/c.dart';\n"
          "import 'package:d/d.dart'\n"
          '    hide D;\n'
          "import 'package:b/b.dart';\n"
          '\n'
          'void main() {}\n',
        );
      });

      test('inserts after a multi-line as directive', () {
        final content = addImports(
          "import 'package:a/a.dart'\n    deferred as a;\n\nvoid main() {}\n",
          ["import 'package:b/b.dart';"],
        );

        expect(
          content,
          "import 'package:a/a.dart'\n"
          '    deferred as a;\n'
          "import 'package:b/b.dart';\n"
          '\n'
          'void main() {}\n',
        );
      });

      test('inserts after a conditional import spanning three lines', () {
        final content = addImports(
          "import 'a.dart'\n"
          "    if (dart.library.io) 'b.dart'\n"
          "    if (dart.library.html) 'c.dart';\n"
          '\n'
          'void main() {}\n',
          ["import 'package:d/d.dart';"],
        );

        expect(
          content,
          "import 'a.dart'\n"
          "    if (dart.library.io) 'b.dart'\n"
          "    if (dart.library.html) 'c.dart';\n"
          "import 'package:d/d.dart';\n"
          '\n'
          'void main() {}\n',
        );
      });

      test('does not insert an import already present in multi-line form', () {
        const source =
            "import 'package:a/a.dart'\n    show A;\n\nvoid main() {}\n";

        final content = addImports(source, [
          "import 'package:a/a.dart' show A;",
          "import 'package:a/a.dart' show A;",
        ]);

        expect(content, source);
      });

      test('compares directives by collapsed whitespace and ignores a comment', () {
        const source =
            "import 'package:a/a.dart'  show   A; // keep\n\nvoid main() {}\n";

        final content = addImports(source, [
          "import 'package:a/a.dart' show A",
        ]);

        expect(content, source);
      });

      test('treats a different combinator as a different import', () {
        final content = addImports(
          "import 'package:a/a.dart'\n    show A;\n\nvoid main() {}\n",
          ["import 'package:a/a.dart' show B;"],
        );

        expect(
          content,
          "import 'package:a/a.dart'\n"
          '    show A;\n'
          "import 'package:a/a.dart' show B;\n"
          '\n'
          'void main() {}\n',
        );
      });

      test('inserts after a directive that carries a comment after the `;`', () {
        final content = addImports(
          "import 'package:a/a.dart'\n    show A; // keep\n\nvoid main() {}\n",
          ["import 'package:b/b.dart';"],
        );

        expect(
          content,
          "import 'package:a/a.dart'\n"
          '    show A; // keep\n'
          "import 'package:b/b.dart';\n"
          '\n'
          'void main() {}\n',
        );
      });

      test('strips a trailing comment from the statement before the `;`', () {
        final content = addImports(
          "import 'package:a/a.dart';\n\nvoid main() {}\n",
          [
            "import 'package:b/b.dart' // note",
            "import 'package:c/c.dart'; // note",
          ],
        );

        expect(
          content,
          "import 'package:a/a.dart';\n"
          "import 'package:b/b.dart';\n"
          "import 'package:c/c.dart';\n"
          '\n'
          'void main() {}\n',
        );
      });

      test('recognises an import written without a space', () {
        final content = addImports(
          "import'package:a/a.dart';\n\nvoid main() {}\n",
          ["import 'package:b/b.dart';"],
        );

        expect(
          content,
          "import'package:a/a.dart';\n"
          "import 'package:b/b.dart';\n"
          '\n'
          'void main() {}\n',
        );
      });

      test(
        'a `;` or `//` inside the URI string does not end the directive',
        () {
          final content = addImports(
            "import 'https://example.com/a;b.dart'\n    show A;\n\n"
            'void main() {}\n',
            ["import 'package:b/b.dart';"],
          );

          expect(
            content,
            "import 'https://example.com/a;b.dart'\n"
            '    show A;\n'
            "import 'package:b/b.dart';\n"
            '\n'
            'void main() {}\n',
          );
        },
      );

      test('ignores an import inside a block comment', () {
        final content = addImports(
          '/*\n'
          "import 'package:old/old.dart';\n"
          '*/\n'
          "import 'package:a/a.dart';\n"
          '\n'
          'void main() {}\n',
          ["import 'package:b/b.dart';", "import 'package:old/old.dart';"],
        );

        expect(
          content,
          '/*\n'
          "import 'package:old/old.dart';\n"
          '*/\n'
          "import 'package:a/a.dart';\n"
          "import 'package:b/b.dart';\n"
          "import 'package:old/old.dart';\n"
          '\n'
          'void main() {}\n',
        );
      });

      test('stops at an export line and inserts before it', () {
        final content = addImports(
          "import 'package:a/a.dart';\nexport 'package:e/e.dart';\n",
          ["import 'package:b/b.dart';"],
        );

        expect(
          content,
          "import 'package:a/a.dart';\n"
          "import 'package:b/b.dart';\n"
          "export 'package:e/e.dart';\n",
        );
      });

      test('inserts at the top of a file with no imports', () {
        final content = addImports('void main() {}\n', [
          "import 'package:b/b.dart'",
        ]);

        expect(content, "import 'package:b/b.dart';\nvoid main() {}\n");
      });

      test('an import inside a nested block comment is not an import', () {
        final content = addImports(
          "/* outer /* inner */\n"
          "import 'package:b/b.dart';\n"
          "*/\n"
          "import 'package:a/a.dart';\n",
          ["import 'package:b/b.dart';"],
        );

        expect(
          content,
          "/* outer /* inner */\n"
          "import 'package:b/b.dart';\n"
          "*/\n"
          "import 'package:a/a.dart';\n"
          "import 'package:b/b.dart';\n",
        );
      });

      test('the first import goes below a library directive', () {
        final content = addImports("library example;\n\nvoid main() {}\n", [
          "import 'package:b/b.dart';",
        ]);

        expect(
          content,
          "library example;\n"
          "import 'package:b/b.dart';\n"
          "\n"
          "void main() {}\n",
        );
      });

      test('a string that holds an import line is not a directive', () {
        final content = addImports(
          "import 'package:a/a.dart';\n"
          "const text = '''\n"
          "import 'package:b/b.dart'\n"
          "    show B;\n"
          "''';\n",
          ["import 'package:b/b.dart' show B;"],
        );

        expect(
          content,
          "import 'package:a/a.dart';\n"
          "import 'package:b/b.dart' show B;\n"
          "const text = '''\n"
          "import 'package:b/b.dart'\n"
          "    show B;\n"
          "''';\n",
        );
      });

      test('a second directive on the same line counts as present', () {
        const source =
            "import 'dart:core'; import 'package:a/a.dart' deferred as a;\n";
        final content = addImports(source, [
          "import 'package:a/a.dart' deferred as a;",
        ]);

        expect(content, source);
      });

      test('the import goes after a block comment that trails a directive', () {
        final content = addImports(
          "import 'package:a/a.dart'\n"
          "    show A; /* note\n"
          "   more */\n"
          "void main() {}\n",
          ["import 'package:b/b.dart';"],
        );

        expect(
          content,
          "import 'package:a/a.dart'\n"
          "    show A; /* note\n"
          "   more */\n"
          "import 'package:b/b.dart';\n"
          "void main() {}\n",
        );
      });

      test('whitespace around commas does not make a directive new', () {
        const source = "import 'package:a/a.dart' show A , B;\n";
        final content = addImports(source, [
          "import 'package:a/a.dart'\n    show A,B;",
        ]);

        expect(content, source);
      });

      test('a different show list is a different directive', () {
        final content = addImports("import 'package:a/a.dart' show A, B;\n", [
          "import 'package:a/a.dart' show A, C;",
        ]);

        expect(content, contains('show A, C;'));
        expect(content, contains('show A, B;'));
      });

      test('the first import goes below a shebang', () {
        final content = addImports('#!/usr/bin/env dart\n\nvoid main() {}\n', [
          "import 'dart:io';",
        ]);

        expect(
          content,
          '#!/usr/bin/env dart\n'
          "import 'dart:io';\n"
          '\n'
          'void main() {}\n',
        );
      });

      test('the import goes below an annotated library directive', () {
        final content = addImports(
          '@deprecated\nlibrary example;\n\nvoid main() {}\n',
          ["import 'dart:io';"],
        );

        expect(
          content,
          '@deprecated\n'
          'library example;\n'
          "import 'dart:io';\n"
          '\n'
          'void main() {}\n',
        );
      });

      test('an annotated import is still an import', () {
        const source = "@Deprecated('old')\nimport 'dart:io';\n";

        expect(addImports(source, ["import 'dart:io';"]), source);
      });

      test('a function called library is not a library directive', () {
        final content = addImports('library() => 1;\n', ["import 'dart:io';"]);

        expect(content, "import 'dart:io';\nlibrary() => 1;\n");
      });

      test('a comment between import and its URI is accepted', () {
        const source = "import /* note */ 'dart:math';\n";

        expect(addImports(source, ["import 'dart:math';"]), source);
        expect(
          addImports("import 'dart:io';\n", ["import /* note */ 'dart:math';"]),
          "import 'dart:io';\nimport 'dart:math';\n",
        );
      });

      test('the import goes before a part directive on the same line', () {
        final content = addImports("import 'dart:math'; part 'piece.dart';\n", [
          "import 'dart:io';",
        ]);

        expect(
          content,
          "import 'dart:math'; import 'dart:io';\npart 'piece.dart';\n",
        );
      });

      test('URIs that differ only in a comma or a semicolon stay distinct', () {
        final content = addImports("import 'a,b.dart';\n", [
          "import 'a;b.dart';",
        ]);

        expect(content, "import 'a,b.dart';\nimport 'a;b.dart';\n");
      });

      test(
        'import with and without a space before the URI is one directive',
        () {
          const spaceless = "import'package:a/a.dart' deferred as a;\n";
          const spaced = "import 'package:a/a.dart' deferred as a;";

          expect(addImports(spaceless, [spaced]), spaceless);
          expect(
            addImports("$spaced\n", [
              "import'package:a/a.dart' deferred as a;",
            ]),
            "$spaced\n",
          );
        },
      );

      test(
        'a comment with a closing parenthesis inside annotation arguments',
        () {
          final content = addImports(
            "@Deprecated(/* ) */ 'old')\nlibrary example;\n",
            ["import 'dart:io';"],
          );

          expect(
            content,
            "@Deprecated(/* ) */ 'old')\n"
            'library example;\n'
            "import 'dart:io';\n",
          );
        },
      );

      test('whitespace inside the requested URI is kept', () {
        final content = addImports("import 'dart:io';\n", [
          "import 'two  spaces.dart';",
        ]);

        expect(content, "import 'dart:io';\nimport 'two  spaces.dart';\n");
      });

      test('takes a statement wrapped over several lines, idempotently', () {
        const wrapped = "import 'package:b/b.dart'\n    show B;";
        final content = addImports("import 'package:a/a.dart';\n", [
          wrapped,
          wrapped,
        ]);

        expect(
          content,
          "import 'package:a/a.dart';\n"
          "import 'package:b/b.dart'\n"
          '    show B;\n',
        );
      });

      const notOneImport = <String, String>{
        'two directives on one line':
            "import 'package:b/b.dart'; import 'package:c/c.dart';",
        'two directives on two lines':
            "import 'package:b/b.dart';\nimport 'package:c/c.dart';",
        'an export': "export 'package:b/b.dart';",
        'a part': "part 'b.g.dart';",
        'an empty statement': '',
        'a comment only': '// nothing to import',
        'a directive with no quoted URI': 'import bogus;',
        'an alias with no name': "import 'dart:math' as;",
        'a show with no names': "import 'a.dart' show ;",
        'a hide with no names': "import 'a.dart' hide ;",
        'a numeric alias': "import 'dart:math' as 123;",
        'an empty conditional': "import 'a.dart' if () 'b.dart';",
      };

      for (final entry in notOneImport.entries) {
        test('refuses ${entry.key} and leaves the file as it was', () {
          const source = "import 'package:a/a.dart';\n\nvoid main() {}\n";
          File(dartPath).writeAsStringSync(source);

          expect(
            () => ConfigEditor.addImportToFile(
              filePath: dartPath,
              importStatement: entry.value,
            ),
            throwsArgumentError,
          );
          expect(File(dartPath).readAsStringSync(), source);
        });
      }
    });

    test('insertCodeBeforePattern / insertCodeAfterPattern', () {
      final filePath = p.join(tempDir.path, 'snippet.dart');
      File(filePath).writeAsStringSync('A\nMARK\nC\n');

      ConfigEditor.insertCodeBeforePattern(
        filePath: filePath,
        pattern: 'MARK',
        code: 'B-before\n',
      );
      ConfigEditor.insertCodeAfterPattern(
        filePath: filePath,
        pattern: 'MARK',
        code: '\nB-after',
      );

      final content = File(filePath).readAsStringSync();
      expect(content, contains('B-before'));
      expect(content, contains('B-after'));
    });

    test('createConfigFile writes content (creating parent dirs)', () {
      final newPath = p.join(tempDir.path, 'nested', 'config.json');

      ConfigEditor.createConfigFile(path: newPath, content: '{"k":1}');

      expect(File(newPath).readAsStringSync(), '{"k":1}');
    });

    test('addDevDependencyToPubspec inserts under dev_dependencies', () {
      ConfigEditor.addDevDependencyToPubspec(
        pubspecPath: pubspecPath,
        name: 'build_runner',
        version: '^2.4.0',
      );

      final content = File(pubspecPath).readAsStringSync();
      expect(content, contains('dev_dependencies:'));
      expect(content, contains('build_runner: ^2.4.0'));
      // The runtime dependency stays put.
      expect(content, contains('meta: ^1.0.0'));
    });

    test('addDevDependencyToPubspec updates existing entry', () {
      ConfigEditor.addDevDependencyToPubspec(
        pubspecPath: pubspecPath,
        name: 'build_runner',
        version: '^2.4.0',
      );
      ConfigEditor.addDevDependencyToPubspec(
        pubspecPath: pubspecPath,
        name: 'build_runner',
        version: '^2.5.0',
      );

      final content = File(pubspecPath).readAsStringSync();
      expect(content, contains('build_runner: ^2.5.0'));
      expect(content, isNot(contains('build_runner: ^2.4.0')));
    });

    test('appendPubspecListEntry creates flutter.assets list when absent', () {
      ConfigEditor.appendPubspecListEntry(
        pubspecPath: pubspecPath,
        keyPath: <String>['flutter', 'assets'],
        value: 'assets/config.json',
      );

      final content = File(pubspecPath).readAsStringSync();
      expect(content, contains('flutter:'));
      expect(content, contains('assets:'));
      expect(content, contains('assets/config.json'));
    });

    test('appendPubspecListEntry preserves existing assets list', () {
      // Pre-populate flutter.assets with one entry. This is the regression
      // test that proves the helper does NOT clobber via updatePubspecValue.
      File(pubspecPath).writeAsStringSync(
        'name: host_app\n'
        'version: 1.0.0\n'
        '\n'
        'flutter:\n'
        '  assets:\n'
        '    - assets/old.json\n',
      );

      ConfigEditor.appendPubspecListEntry(
        pubspecPath: pubspecPath,
        keyPath: <String>['flutter', 'assets'],
        value: 'assets/new.json',
      );

      final content = File(pubspecPath).readAsStringSync();
      expect(content, contains('assets/old.json'));
      expect(content, contains('assets/new.json'));
    });

    test('appendPubspecListEntry is idempotent on duplicate value', () {
      File(pubspecPath).writeAsStringSync(
        'name: host_app\n'
        'flutter:\n'
        '  assets:\n'
        '    - assets/x.json\n',
      );
      final before = File(pubspecPath).readAsStringSync();

      ConfigEditor.appendPubspecListEntry(
        pubspecPath: pubspecPath,
        keyPath: <String>['flutter', 'assets'],
        value: 'assets/x.json',
      );

      expect(File(pubspecPath).readAsStringSync(), before);
    });

    test('appendPubspecListEntry throws when target is a non-list scalar', () {
      File(pubspecPath).writeAsStringSync(
        'name: host_app\n'
        'flutter:\n'
        '  assets: not_a_list\n',
      );

      expect(
        () => ConfigEditor.appendPubspecListEntry(
          pubspecPath: pubspecPath,
          keyPath: <String>['flutter', 'assets'],
          value: 'assets/x.json',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('ConfigEditor idempotency', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dowel_cfg_editor_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test(
      'insertCodeAfterPattern skips when code already present after pattern',
      () {
        final filePath = p.join(tempDir.path, 'after_idempotent.dart');
        // Seed: pattern already followed by the code we intend to inject.
        File(filePath).writeAsStringSync('MARK\ninjected_code\n');
        final before = File(filePath).readAsStringSync();

        ConfigEditor.insertCodeAfterPattern(
          filePath: filePath,
          pattern: 'MARK',
          code: '\ninjected_code\n',
        );

        // File must be byte-for-byte identical; no duplicate injection.
        expect(File(filePath).readAsStringSync(), before);
      },
    );

    test('insertCodeAfterPattern inserts when code is different from any existing snippet', () {
      final filePath = p.join(tempDir.path, 'after_inserts.dart');
      // Seed: pattern exists but the target code is absent.
      File(filePath).writeAsStringSync('MARK\nother_code\n');
      final before = File(filePath).readAsStringSync();

      ConfigEditor.insertCodeAfterPattern(
        filePath: filePath,
        pattern: 'MARK',
        code: '\nnew_code\n',
      );

      final after = File(filePath).readAsStringSync();
      // The file must have grown (insertion happened).
      expect(after.length, greaterThan(before.length));
      expect(after, contains('new_code'));
    });

    test(
      'insertCodeBeforePattern skips when code already present before pattern',
      () {
        final filePath = p.join(tempDir.path, 'before_idempotent.dart');
        // Seed: the code we intend to inject already precedes the pattern.
        File(filePath).writeAsStringSync('injected_code\nMARK\n');
        final before = File(filePath).readAsStringSync();

        ConfigEditor.insertCodeBeforePattern(
          filePath: filePath,
          pattern: 'MARK',
          code: 'injected_code\n',
        );

        // File must be byte-for-byte identical; no duplicate injection.
        expect(File(filePath).readAsStringSync(), before);
      },
    );

    test('insertCodeBeforePattern inserts when code is different', () {
      final filePath = p.join(tempDir.path, 'before_inserts.dart');
      // Seed: pattern exists but the target code is absent.
      File(filePath).writeAsStringSync('other_code\nMARK\n');
      final before = File(filePath).readAsStringSync();

      ConfigEditor.insertCodeBeforePattern(
        filePath: filePath,
        pattern: 'MARK',
        code: 'new_code\n',
      );

      final after = File(filePath).readAsStringSync();
      // The file must have grown (insertion happened).
      expect(after.length, greaterThan(before.length));
      expect(after, contains('new_code'));
    });
  });
}

import 'dart:convert';

import 'package:dowel/dowel.dart';
import 'package:test/test.dart';

/// Minimal no-op [PromptDriver] for conflict-detector tests.
class _SilentPromptDriver implements PromptDriver {
  @override
  String ask(
    String question, {
    String? defaultValue,
    String? Function(String)? validator,
  }) => defaultValue ?? '';

  @override
  bool confirm(String question, {bool defaultValue = false}) => defaultValue;

  @override
  String choice(
    String question, {
    required List<String> options,
    String? defaultValue,
  }) => defaultValue ?? options.first;

  @override
  String secret(String question) => '';
}

/// Minimal no-op [StubDriver] for conflict-detector tests.
class _SilentStubDriver implements StubDriver {
  @override
  String load(String name, {List<String>? searchPaths}) => '';

  @override
  String replace(String stub, Map<String, String> replacements) => stub;

  @override
  String make(String name, Map<String, String> replacements) => '';
}

InstallContext _makeCtx({required VirtualFs fs}) {
  return InstallContext.test(
    fs: fs,
    prompt: _SilentPromptDriver(),
    stubs: _SilentStubDriver(),
    projectRoot: '/proj',
  );
}

/// Writes a plugin record file at the expected location.
///
/// The [hashes] map keys are project-relative, forward-slash paths; values are
/// md5 hex strings.
void _writeRecord(
  InMemoryFs fs,
  String pluginName,
  Map<String, String> hashes,
) {
  final recordPath = '/proj/.dowel/installed/$pluginName.json';
  final record = <String, dynamic>{
    'version': 1,
    'plugin': pluginName,
    'installedAt': '2025-01-01T00:00:00.000Z',
    'ops': <dynamic>[],
    'stubHashes': hashes,
  };
  fs.writeAsString(recordPath, jsonEncode(record));
}

void main() {
  group('ConflictDetector.detect()', () {
    test(
      'returns empty list when target file does not exist (clean install)',
      () {
        final fs = InMemoryFs();
        // No pre-existing file at /proj/lib/a.dart.
        final ctx = _makeCtx(fs: fs);
        final detector = ConflictDetector(ctx);

        final conflicts = detector.detect(const [
          WriteFile(targetPath: 'lib/a.dart', content: 'hello'),
        ], pluginName: 'demo');

        expect(conflicts, isEmpty);
      },
    );

    test('returns unmanaged-file conflict when file exists but no record file '
        'is present', () {
      final fs = InMemoryFs();
      fs.writeAsString('/proj/lib/a.dart', 'existing content');
      // No record file written.
      final ctx = _makeCtx(fs: fs);
      final detector = ConflictDetector(ctx);

      final conflicts = detector.detect(const [
        WriteFile(targetPath: 'lib/a.dart', content: 'new'),
      ], pluginName: 'demo');

      expect(conflicts, hasLength(1));
      expect(conflicts.first.absPath, '/proj/lib/a.dart');
      expect(conflicts.first.reason, 'unmanaged-file');
    });

    test('returns no conflict when file exists and recorded hash matches '
        'current file content', () {
      final fs = InMemoryFs();
      const fileContent = 'unchanged content';
      fs.writeAsString('/proj/lib/a.dart', fileContent);
      // Record the md5 of the current content so it looks unmodified.
      final currentHash = fs.md5('/proj/lib/a.dart');
      _writeRecord(fs, 'demo', {'lib/a.dart': currentHash});
      final ctx = _makeCtx(fs: fs);
      final detector = ConflictDetector(ctx);

      final conflicts = detector.detect(const [
        WriteFile(targetPath: 'lib/a.dart', content: 'new'),
      ], pluginName: 'demo');

      expect(conflicts, isEmpty);
    });

    test('returns modified-since-last-known-stub conflict when file exists and '
        'recorded hash diverges from current content', () {
      final fs = InMemoryFs();
      fs.writeAsString('/proj/lib/a.dart', 'original content');
      final originalHash = fs.md5('/proj/lib/a.dart');
      // Now the user modifies the file.
      fs.writeAsString('/proj/lib/a.dart', 'user-modified content');
      // Record still holds the original hash.
      _writeRecord(fs, 'demo', {'lib/a.dart': originalHash});
      final ctx = _makeCtx(fs: fs);
      final detector = ConflictDetector(ctx);

      final conflicts = detector.detect(const [
        WriteFile(targetPath: 'lib/a.dart', content: 'new'),
      ], pluginName: 'demo');

      expect(conflicts, hasLength(1));
      expect(conflicts.first.absPath, '/proj/lib/a.dart');
      expect(conflicts.first.reason, 'modified-since-last-known-stub');
      expect(conflicts.first.lastKnownHash, originalHash);
      expect(conflicts.first.currentHash, fs.md5('/proj/lib/a.dart'));
    });

    test(
      'handles mixed ops: some clean, some conflicting, across multiple files',
      () {
        final fs = InMemoryFs();
        // File A: unmodified (matching hash).
        const contentA = 'content a';
        fs.writeAsString('/proj/lib/a.dart', contentA);
        final hashA = fs.md5('/proj/lib/a.dart');
        // File B: user-modified (diverging hash).
        fs.writeAsString('/proj/lib/b.dart', 'original b');
        final originalHashB = fs.md5('/proj/lib/b.dart');
        fs.writeAsString('/proj/lib/b.dart', 'user changed b');
        // File C: does not exist yet (clean install).
        _writeRecord(fs, 'demo', {
          'lib/a.dart': hashA,
          'lib/b.dart': originalHashB,
        });
        final ctx = _makeCtx(fs: fs);
        final detector = ConflictDetector(ctx);

        final conflicts = detector.detect(const [
          WriteFile(targetPath: 'lib/a.dart', content: 'new a'),
          WriteFile(targetPath: 'lib/b.dart', content: 'new b'),
          WriteFile(targetPath: 'lib/c.dart', content: 'new c'),
        ], pluginName: 'demo');

        expect(conflicts, hasLength(1));
        expect(conflicts.first.absPath, '/proj/lib/b.dart');
        expect(conflicts.first.reason, 'modified-since-last-known-stub');
      },
    );

    test('RunShell and AddDependency ops never produce conflicts against an '
        'unrecorded pubspec on disk', () {
      final fs = InMemoryFs();
      fs.writeAsString('/proj/pubspec.yaml', 'name: consumer\n');
      final ctx = _makeCtx(fs: fs);
      final detector = ConflictDetector(ctx);

      final conflicts = detector.detect(const [
        RunShell(command: 'dart', args: ['format', '.']),
        AddDependency(name: 'foo', version: '^1.0.0'),
        RemoveDependency(name: 'bar'),
      ], pluginName: 'demo');

      expect(conflicts, isEmpty);
    });

    test('a helper-edited file changed since the recorded hash is not a '
        'conflict', () {
      // The user ran `dart pub add` after the install, so the pubspec no
      // longer matches the hash the record kept. A reinstall edits it in
      // place again; demanding --force here switched off every other check.
      final fs = InMemoryFs();
      fs.writeAsString('/proj/pubspec.yaml', 'name: consumer\n');
      _writeRecord(fs, 'demo', {'pubspec.yaml': fs.md5('/proj/pubspec.yaml')});
      fs.writeAsString(
        '/proj/pubspec.yaml',
        'name: consumer\ndependencies:\n  http: ^1.0.0\n',
      );
      final detector = ConflictDetector(_makeCtx(fs: fs));

      final conflicts = detector.detect(const [
        AddDependency(name: 'foo', version: '^1.0.0'),
      ], pluginName: 'demo');

      expect(conflicts, isEmpty);
    });
  });

  group('ConflictDetector.detect() install record format', () {
    test('a record without a version is reported as unsupported', () {
      final fs = InMemoryFs();
      fs.writeAsString(
        '/proj/.dowel/installed/demo.json',
        jsonEncode(<String, dynamic>{
          'plugin': 'demo',
          'ops': <dynamic>[],
          'stubHashes': <String, String>{},
        }),
      );
      final detector = ConflictDetector(_makeCtx(fs: fs));

      final conflicts = detector.detect(const [
        WriteFile(targetPath: 'lib/a.dart', content: 'new'),
      ], pluginName: 'demo');

      expect(conflicts, hasLength(1));
      expect(conflicts.single.absPath, '/proj/.dowel/installed/demo.json');
      expect(conflicts.single.reason, 'unsupported-install-record');
    });

    test(
      'a record with absolute stubHashes keys is reported as unsupported',
      () {
        final fs = InMemoryFs();
        fs.writeAsString('/proj/lib/a.dart', 'content');
        fs.writeAsString(
          '/proj/.dowel/installed/demo.json',
          jsonEncode(<String, dynamic>{
            'version': 1,
            'plugin': 'demo',
            'ops': <dynamic>[],
            'stubHashes': <String, String>{
              '/proj/lib/a.dart': fs.md5('/proj/lib/a.dart'),
            },
          }),
        );
        final detector = ConflictDetector(_makeCtx(fs: fs));

        final conflicts = detector.detect(const [
          WriteFile(targetPath: 'lib/a.dart', content: 'new'),
        ], pluginName: 'demo');

        expect(
          conflicts.map((conflict) => conflict.reason),
          containsAll(<String>['unsupported-install-record', 'unmanaged-file']),
        );
      },
    );

    test('a record with a source path outside the project is unsupported', () {
      final fs = InMemoryFs();
      fs.writeAsString(
        '/proj/.dowel/installed/demo.json',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'plugin': 'demo',
          'ops': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'CopyFile',
              'sourcePath': '../secrets.env',
              'targetPath': 'lib/a.dart',
            },
          ],
          'stubHashes': <String, String>{},
        }),
      );
      final detector = ConflictDetector(_makeCtx(fs: fs));

      final conflicts = detector.detect(const [
        WriteFile(targetPath: 'lib/a.dart', content: 'new'),
      ], pluginName: 'demo');

      expect(conflicts.single.reason, 'unsupported-install-record');
    });

    test('a record that is not JSON is reported instead of thrown', () {
      final fs = InMemoryFs();
      fs.writeAsString('/proj/.dowel/installed/demo.json', '{not json');
      final detector = ConflictDetector(_makeCtx(fs: fs));

      final conflicts = detector.detect(const [
        WriteFile(targetPath: 'lib/a.dart', content: 'new'),
      ], pluginName: 'demo');

      expect(conflicts.single.reason, 'unsupported-install-record');
    });

    test('relative keys still match after the project moves', () {
      // The same record under another root: absolute keys made every file
      // read as unmanaged once the checkout moved.
      final fs = InMemoryFs();
      fs.writeAsString('/proj/lib/a.dart', 'content');
      _writeRecord(fs, 'demo', {'lib/a.dart': fs.md5('/proj/lib/a.dart')});
      fs.copy('/proj/lib/a.dart', '/moved/lib/a.dart');
      fs.copy(
        '/proj/.dowel/installed/demo.json',
        '/moved/.dowel/installed/demo.json',
      );
      final detector = ConflictDetector(
        InstallContext.test(
          fs: fs,
          prompt: _SilentPromptDriver(),
          stubs: _SilentStubDriver(),
          projectRoot: '/moved',
        ),
      );

      final conflicts = detector.detect(const [
        WriteFile(targetPath: 'lib/a.dart', content: 'new'),
      ], pluginName: 'demo');

      expect(conflicts, isEmpty);
    });
  });
}

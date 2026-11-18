import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../console/command_boot.dart';
import '../console/dowel_command.dart';
import '../console/dowel_context.dart';
import '../helpers/file_helper.dart';
import 'helpers/generated_dart_layout.dart';

/// `dowel test:bundle`: writes `test/bundle_<n>.g.dart` entries that together
/// run every `*_test.dart` under `test/`, each file inside a group named
/// after its path.
///
/// `flutter test` compiles every test file on its own; a few entries compile
/// a few times instead. The names do not end in `_test.dart`, so a plain
/// `flutter test` does not discover them and run every test twice.
///
/// Files are dealt heaviest first (by line count) onto the lightest of
/// `--shards` entries; a file with a `// shard: alone` line goes to
/// `test/bundle_alone.g.dart` instead. A file the bundle cannot run as
/// written is refused, never skipped, and a refusal writes nothing.
final class TestBundleCommand extends DowelCommand {
  /// [projectRoot] pins the project to bundle; it defaults to the nearest
  /// `pubspec.yaml` above the working directory.
  TestBundleCommand({this._projectRoot});

  final String? _projectRoot;

  @override
  String get signature =>
      'test:bundle '
      '{--shards=3 : How many entries the dealt files are spread over, '
      'capped at the number of files left to deal} '
      '{--only= : Bundle only the files in this list, one path per line '
      '(test/foo_test.dart)}';

  @override
  String get description =>
      'Write test/bundle_<n>.g.dart entries that run every *_test.dart in '
      'a few compilations.';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  Future<int> handle(DowelContext ctx) async {
    // 1. Validate the options before touching the tree.
    final rawShards = (ctx.input.option('shards') as String?) ?? '3';
    final shards = RegExp(r'^[0-9]+$').hasMatch(rawShards)
        ? int.tryParse(rawShards)
        : null;
    if (shards == null || shards == 0) {
      ctx.output.error('--shards takes a positive integer, got "$rawShards".');
      return 1;
    }
    final only = ctx.input.option('only') as String?;
    if (only != null && only.isEmpty) {
      ctx.output.error('--only needs a list file.');
      return 1;
    }

    final root = _projectRoot ?? FileHelper.findProjectRoot();
    final testDir = Directory(p.join(root, 'test'));
    final tree = _listTree(testDir);
    final problems = <String>[];

    // 2. Collect the candidate files, relative to test/ and sorted bytewise.
    final List<String> files;
    if (only == null) {
      files = <String>[
        for (final path in tree)
          if (path.endsWith('_test.dart')) path,
      ];
      if (files.isEmpty) {
        ctx.output.error('Found no *_test.dart under test/.');
        return 1;
      }
    } else {
      final requested = _readList(only);
      if (requested == null) {
        ctx.output.error('--only list $only is not readable.');
        return 1;
      }
      files = <String>[];
      for (final entry in requested) {
        final problem = _listedPathProblem(entry, root);
        if (problem != null) {
          problems.add(problem);
        } else {
          files.add(entry.substring('test/'.length));
        }
      }

      // Nothing to run: still clear the bundles of an earlier run, or a
      // stale shard would run files this subset never named.
      if (files.isEmpty && problems.isEmpty) {
        _removeStaleBundles(testDir);
        ctx.output.info('--only list names no test file; no bundle written.');
        return 0;
      }
    }

    // 3. Refuse what a bundle cannot run as written, naming every file.
    final sources = <String, String>{
      for (final path in files)
        // A file that is not UTF-8 still gets its checks and its refusal.
        path: utf8.decode(
          File(p.join(testDir.path, path)).readAsBytesSync(),
          allowMalformed: true,
        ),
    };
    for (final MapEntry(key: path, value: source) in sources.entries) {
      problems.addAll(_sourceProblems(path, source));
    }
    for (final path in tree) {
      if (p.posix.basename(path) == 'flutter_test_config.dart' &&
          path != 'flutter_test_config.dart') {
        problems.add(
          'test/$path: Flutter looks flutter_test_config.dart up from each '
          "test file's directory upwards and stops at pubspec.yaml, so a "
          'bundle in test/ never sees this one and the files below it would '
          'lose their wrapper.',
        );
      }
    }
    final seen = <String>{};
    final duplicates = <String>{
      for (final path in files)
        if (!seen.add(path)) path,
    };
    for (final path in duplicates) {
      problems.add('listed twice: test/$path');
    }
    if (problems.isNotEmpty) {
      return _refuse(ctx, problems);
    }

    // 4. Split off the files that run alone; something must be left to deal
    //    unless a subset was asked for.
    final alone = <String>[
      for (final path in files)
        if (_alonePattern.hasMatch(sources[path]!)) path,
    ];
    final dealt = <String>[
      for (final path in files)
        if (!alone.contains(path)) path,
    ];
    if (only == null && dealt.isEmpty) {
      return _refuse(ctx, <String>[
        'every test file is marked `// shard: alone`, so no shard is left to '
            'deal files onto.',
      ]);
    }

    // 5. Deal, render and write every entry in one go.
    final shardMembers = _deal(<(String, int)>[
      for (final path in dealt) (path, _lineCount(sources[path]!)),
    ], shards < dealt.length ? shards : dealt.length);
    final bundles = <String, List<String>>{
      for (var s = 0; s < shardMembers.length; s++)
        'bundle_$s.g.dart': shardMembers[s],
      if (alone.isNotEmpty) 'bundle_alone.g.dart': alone,
    };
    _writeBundles(testDir, bundles);

    // 6. Report what each entry holds.
    ctx.output.success(
      'Bundled ${files.length} test file(s): ${shardMembers.length} '
      'shard(s) and ${alone.length} alone.',
    );
    for (final MapEntry(key: name, value: members) in bundles.entries) {
      ctx.output.writeln('  - test/$name (${members.length} file(s))');
    }
    return 0;
  }

  int _refuse(DowelContext ctx, List<String> problems) {
    problems.forEach(ctx.output.error);
    ctx.output.error('${problems.length} problem(s); nothing written.');
    return 1;
  }

  /// Every non-directory path below [testDir], relative to it with `/`
  /// separators, sorted by code unit (the paths that pass the character rule
  /// are ASCII, so this is the bytewise order).
  List<String> _listTree(Directory testDir) {
    if (!testDir.existsSync()) return <String>[];

    return <String>[
      for (final entity in testDir.listSync(
        recursive: true,
        followLinks: false,
      ))
        if (entity is! Directory)
          p.posix.joinAll(p.split(p.relative(entity.path, from: testDir.path))),
    ]..sort();
  }

  /// The non-blank lines of the `--only` list, sorted so a path listed twice
  /// sits beside its copy; `null` when [path] is not a readable file.
  List<String>? _readList(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;

    return <String>[
      for (final line in file.readAsLinesSync())
        if (line.trim().isNotEmpty) line,
    ]..sort();
  }

  /// Why a `--only` [entry] cannot be bundled, or `null` when it can. An
  /// entry is a normalised project-relative path below `test/`.
  String? _listedPathProblem(String entry, String root) {
    final segments = entry.split('/');
    final normalised =
        segments.length > 1 &&
        segments.first == 'test' &&
        !segments.any((s) => s.isEmpty || s == '.' || s == '..');
    if (!normalised) return '$entry is not under test/';
    if (!entry.endsWith('_test.dart')) {
      return '$entry does not end in _test.dart';
    }
    if (!File(p.join(root, entry)).existsSync()) {
      return '$entry does not exist';
    }
    return null;
  }

  /// The rules a test file at [path] (relative to `test/`) breaks.
  List<String> _sourceProblems(String path, String source) {
    final problems = <String>[];

    // The path lands inside a single-quoted Dart literal: a quote, `$` or
    // `\` would end or rewrite it.
    if (!_pathPattern.hasMatch(path)) {
      problems.add(
        'test/$path has a character outside [A-Za-z0-9_./-] in its path.',
      );
    }
    final annotation = _libraryAnnotationPattern.firstMatch(source);
    if (annotation != null) {
      problems.add(
        'test/$path carries @${annotation.group(1)}, a library annotation '
        'that binds the file as a suite and means nothing inside a group.',
      );
    }
    if (_syncMainPattern.allMatches(source).length != 1) {
      final asyncMain = _asyncMainPattern.firstMatch(source);
      problems.add(
        asyncMain != null
            ? 'test/$path declares `${asyncMain.group(1)}<void> main`; a '
                  "group body is synchronous, so it needs one 'void main() {'."
            : "test/$path has no single 'void main() {' to run inside a "
                  'group.',
      );
    }
    return problems;
  }

  /// Deals [weighted] files heaviest first onto the lightest of [shards]
  /// entries (ties by path, then by the lowest shard), so the same tree
  /// always deals the same way. Members come back sorted by path.
  List<List<String>> _deal(List<(String, int)> weighted, int shards) {
    final order = <(String, int)>[...weighted]
      ..sort((a, b) {
        final byWeight = b.$2.compareTo(a.$2);
        return byWeight != 0 ? byWeight : a.$1.compareTo(b.$1);
      });
    final loads = List<int>.filled(shards, 0);
    final members = List<List<String>>.generate(shards, (_) => <String>[]);

    for (final (path, weight) in order) {
      var pick = 0;
      for (var s = 1; s < shards; s++) {
        if (loads[s] < loads[pick]) pick = s;
      }
      loads[pick] += weight;
      members[pick].add(path);
    }
    return <List<String>>[for (final shard in members) shard..sort()];
  }

  /// Lines in [source], a last line without a newline included, so every
  /// file that holds a `main` weighs at least one.
  int _lineCount(String source) {
    if (source.isEmpty) return 0;

    final newlines = '\n'.allMatches(source).length;
    return source.endsWith('\n') ? newlines : newlines + 1;
  }

  /// One entry: every member imported under its own prefix and run inside
  /// a group named after its path, laid out the way `dart format` writes it.
  String _renderBundle(List<String> members) {
    final buffer = StringBuffer()
      ..writeln(formatWidthDirective)
      ..writeln(
        '// GENERATED by dowel test:bundle; do not edit, do not commit.',
      )
      ..writeln("import 'package:flutter_test/flutter_test.dart';")
      ..writeln();
    for (var i = 0; i < members.length; i++) {
      final line = "import '${members[i]}' as t$i;";
      buffer.writeln(
        line.length <= _pageWidth
            ? line
            : "import '${members[i]}'\n    as t$i;",
      );
    }
    buffer
      ..writeln()
      ..writeln('void main() {');
    for (var i = 0; i < members.length; i++) {
      final line = "  group('${members[i]}', t$i.main);";
      buffer.writeln(
        line.length <= _pageWidth
            ? line
            : "  group(\n    '${members[i]}',\n    t$i.main,\n  );",
      );
    }
    buffer.writeln('}');
    return buffer.toString();
  }

  /// Stages every entry as `<name>.tmp` first, so a failed write leaves the
  /// earlier bundles in place, then removes the stale ones (a leftover shard
  /// from a larger count would run its files twice) and renames them in.
  void _writeBundles(Directory testDir, Map<String, List<String>> bundles) {
    final staged = <File>[];
    try {
      for (final MapEntry(key: name, value: members) in bundles.entries) {
        final tmp = File(p.join(testDir.path, '$name.tmp'));
        staged.add(tmp);
        tmp.writeAsStringSync(_renderBundle(members));
      }
    } catch (_) {
      for (final tmp in staged) {
        if (tmp.existsSync()) tmp.deleteSync();
      }
      rethrow;
    }
    _removeStaleBundles(testDir);
    for (final name in bundles.keys) {
      File(p.join(testDir.path, '$name.tmp'))
          .renameSync(p.join(testDir.path, name));
    }
  }

  void _removeStaleBundles(Directory testDir) {
    if (!testDir.existsSync()) return;

    for (final file in testDir.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (name.startsWith('bundle') && name.endsWith('.g.dart')) {
        file.deleteSync();
      }
    }
  }
}

/// The width `formatWidthDirective` pins the generated file to.
const int _pageWidth = 80;

final RegExp _pathPattern = RegExp(r'^[A-Za-z0-9_./-]+$');

final RegExp _libraryAnnotationPattern = RegExp(
  r'^@(TestOn|Tags|Timeout|Skip|Retry|OnPlatform)\b',
  multiLine: true,
);

final RegExp _syncMainPattern = RegExp(r'^void main\(\) \{', multiLine: true);

final RegExp _asyncMainPattern = RegExp(
  r'^(Future|FutureOr)<void> main\(',
  multiLine: true,
);

final RegExp _alonePattern = RegExp(r'^// shard: alone$', multiLine: true);

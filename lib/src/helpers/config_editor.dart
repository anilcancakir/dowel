import 'package:yaml_edit/yaml_edit.dart';

import 'file_helper.dart';

/// Configuration file editing utilities for CLI commands.
///
/// Provides safe YAML editing for pubspec.yaml, code injection into Dart files,
/// and config file creation.
///
/// ## Usage
///
/// ```dart
/// // Add dependency
/// ConfigEditor.addDependencyToPubspec(
///   pubspecPath: 'pubspec.yaml',
///   name: 'http',
///   version: '^1.0.0',
/// );
///
/// // Add import to Dart file
/// ConfigEditor.addImportToFile(
///   filePath: 'lib/main.dart',
///   importStatement: "import 'package:http/http.dart';",
/// );
/// ```
final class ConfigEditor {
  /// Add or update a dependency in pubspec.yaml.
  ///
  /// If the dependency already exists, it will be updated to the new version.
  /// Creates the dependencies section if it doesn't exist.
  static void addDependencyToPubspec({
    required String pubspecPath,
    required String name,
    required String version,
  }) {
    final content = FileHelper.readFile(pubspecPath);
    final editor = YamlEditor(content);

    // Ensure dependencies section exists
    if (editor.parseAt(['dependencies']).value == null) {
      editor.update(['dependencies'], {});
    }

    // Add or update the dependency
    editor.update(['dependencies', name], version);

    // Write the updated content
    FileHelper.writeFile(pubspecPath, editor.toString());
  }

  /// Add or update a path-based dependency in pubspec.yaml.
  ///
  /// Use this for local plugin dependencies that reference a path rather than a version.
  /// Creates the dependencies section if it doesn't exist.
  ///
  /// Example:
  /// ```yaml
  /// dependencies:
  ///   my_plugin:
  ///     path: ./plugins/my_plugin
  /// ```
  static void addPathDependencyToPubspec({
    required String pubspecPath,
    required String name,
    required String path,
  }) {
    final content = FileHelper.readFile(pubspecPath);
    final editor = YamlEditor(content);

    // Ensure dependencies section exists
    try {
      if (editor.parseAt(['dependencies']).value == null) {
        editor.update(['dependencies'], {});
      }
    } catch (e) {
      editor.update(['dependencies'], {});
    }

    // Add or update the dependency with path
    editor.update(['dependencies', name], {'path': path});

    // Write the updated content
    FileHelper.writeFile(pubspecPath, editor.toString());
  }

  /// Remove a dependency from pubspec.yaml.
  ///
  /// Does nothing if the dependency doesn't exist.
  static void removeDependencyFromPubspec({
    required String pubspecPath,
    required String name,
  }) {
    final content = FileHelper.readFile(pubspecPath);
    final editor = YamlEditor(content);

    // Check if dependencies section exists first
    try {
      final deps = editor.parseAt(['dependencies']).value;
      if (deps != null && deps is Map && deps.containsKey(name)) {
        editor.remove(['dependencies', name]);
        FileHelper.writeFile(pubspecPath, editor.toString());
      }
    } catch (e) {
      // Dependencies section doesn't exist, nothing to remove
      return;
    }
  }

  /// Add a dev dependency to `pubspec.yaml` under the `dev_dependencies` map.
  ///
  /// If the dev dependency already exists its version is updated in place.
  /// Creates the `dev_dependencies` section if it does not exist.
  ///
  /// @param pubspecPath  Absolute or relative path to `pubspec.yaml`.
  /// @param name         Package name as published on pub.dev.
  /// @param version      Version constraint, e.g. `^1.0.0`.
  static void addDevDependencyToPubspec({
    required String pubspecPath,
    required String name,
    required String version,
  }) {
    final content = FileHelper.readFile(pubspecPath);
    final editor = YamlEditor(content);

    // 1. Ensure `dev_dependencies` exists. `parseAt` throws when the key path
    //    is missing, so catch and create a fresh map in either no-value or
    //    no-key case.
    try {
      if (editor.parseAt(['dev_dependencies']).value == null) {
        editor.update(['dev_dependencies'], {});
      }
    } catch (_) {
      editor.update(['dev_dependencies'], {});
    }

    // 2. Upsert the dev dependency.
    editor.update(['dev_dependencies', name], version);

    FileHelper.writeFile(pubspecPath, editor.toString());
  }

  /// Append [value] to the YAML list living at [keyPath] inside
  /// [pubspecPath], creating the list if it does not yet exist.
  ///
  /// This differs from [updatePubspecValue] which REPLACES the entire value at
  /// [keyPath]. Append-style mutation is needed for `flutter.assets`,
  /// `flutter.fonts`, and other list-shaped keys that callers (typically
  /// plugin install commands) want to extend without clobbering existing
  /// entries.
  ///
  /// Idempotent: when [value] is already present anywhere in the list, the
  /// file is left unchanged.
  ///
  /// @param pubspecPath  Path to `pubspec.yaml`.
  /// @param keyPath      YAML key path identifying the target list, e.g.
  ///                     `['flutter', 'assets']`.
  /// @param value        Scalar entry to append.
  static void appendPubspecListEntry({
    required String pubspecPath,
    required List<String> keyPath,
    required String value,
  }) {
    final content = FileHelper.readFile(pubspecPath);
    final editor = YamlEditor(content);

    // 1. Build intermediate map nodes when missing so `parseAt(keyPath)` does
    //    not throw on a fresh pubspec. The leaf node itself stays untouched
    //    until step 2 decides whether to create a list or extend one.
    for (var i = 0; i < keyPath.length - 1; i++) {
      final segment = keyPath.sublist(0, i + 1);
      try {
        if (editor.parseAt(segment).value == null) {
          editor.update(segment, {});
        }
      } catch (_) {
        editor.update(segment, {});
      }
    }

    // 2. Read the current list. Absent or null → create a fresh single-entry
    //    list. Wrong shape (scalar / map) is a fatal misuse: refuse to clobber.
    dynamic existing;
    try {
      existing = editor.parseAt(keyPath).value;
    } catch (_) {
      existing = null;
    }

    if (existing == null) {
      editor.update(keyPath, <String>[value]);
      FileHelper.writeFile(pubspecPath, editor.toString());
      return;
    }

    if (existing is! List) {
      throw StateError(
        'appendPubspecListEntry: $keyPath is not a YAML list '
        '(found ${existing.runtimeType}); refusing to clobber.',
      );
    }

    // 3. Dedup by string equality so the operation is idempotent across
    //    repeated installs.
    final merged = <dynamic>[...existing];
    final alreadyPresent = merged.any((entry) => entry?.toString() == value);
    if (alreadyPresent) {
      return;
    }
    merged.add(value);
    editor.update(keyPath, merged);

    FileHelper.writeFile(pubspecPath, editor.toString());
  }

  /// Update a nested value in pubspec.yaml.
  ///
  /// The [keyPath] is a list of keys to traverse, e.g., ['environment', 'sdk'].
  /// Creates missing keys if needed.
  static void updatePubspecValue({
    required String pubspecPath,
    required List<String> keyPath,
    required dynamic value,
  }) {
    final content = FileHelper.readFile(pubspecPath);
    final editor = YamlEditor(content);

    // Build up the path, creating missing sections
    for (var i = 0; i < keyPath.length - 1; i++) {
      final currentPath = keyPath.sublist(0, i + 1);
      try {
        if (editor.parseAt(currentPath).value == null) {
          editor.update(currentPath, {});
        }
      } catch (e) {
        // Path doesn't exist, create it
        editor.update(currentPath, {});
      }
    }

    // Update the final value
    editor.update(keyPath, value);

    // Write the updated content
    FileHelper.writeFile(pubspecPath, editor.toString());
  }

  /// Add an import statement to a Dart file if not already present.
  ///
  /// The import is added after the last import directive of the file's header
  /// (the run of `library`, `import`, `export` and `part` directives before the
  /// first declaration), after the `library` directive of a file with no
  /// import, or at the top of a file with neither. A directive that spans
  /// several lines (`show`, `hide`, `as`, `if (dart.library...)`) is one unit
  /// that ends at its `;`, and the new import never lands inside it or inside
  /// a comment that follows it. A header `export` or `part` closes the place
  /// the import goes, so it stays above them.
  ///
  /// Idempotent: an import directive anywhere in the header with the same
  /// tokens counts as present, whatever its whitespace, line wrapping or
  /// comments. Text inside a declaration, such as a string holding an
  /// `import` line, is never read. Automatically handles adding semicolon if
  /// missing, and drops comments from [importStatement].
  ///
  /// Throws [ArgumentError] when [importStatement] is not exactly one import
  /// directive.
  static void addImportToFile({
    required String filePath,
    required String importStatement,
  }) {
    final content = FileHelper.readFile(filePath);

    // 1. Normalise the statement the way the file's directives are compared.
    final statement = _importStatementOf(importStatement);
    final wanted = _normaliseDirective(statement);

    // 2. Read the header: where the import goes, and what is already there.
    final header = _scanImportHeader(content);
    if (header.imports.contains(wanted)) return;

    // 3. Insert the import on a line of its own at that offset.
    final at = header.insertAt;
    final needsBreak =
        at > 0 && at == content.length && !content.endsWith('\n');
    FileHelper.writeFile(
      filePath,
      '${content.substring(0, at)}${needsBreak ? '\n' : ''}$statement\n'
      '${content.substring(at)}',
    );
  }

  /// Reads the header of [source]: the directives before the first declaration.
  ///
  /// `insertAt` is a line start. `imports` holds every import directive of the
  /// header, normalised for comparison.
  static ({int insertAt, Set<String> imports}) _scanImportHeader(
    String source,
  ) {
    final imports = <String>{};
    var insertAt = 0;
    var afterLibrary = -1;
    var placementOpen = true;
    var sawImport = false;
    var i = 0;

    // A script's shebang stays the first line.
    if (source.startsWith('#!')) {
      i = _lineEnd(source, 0);
      insertAt = _nextLine(source, 0);
    }

    while (i < source.length) {
      final next = _skipTrivia(source, i);
      if (next != i) {
        i = next;
        continue;
      }

      // Metadata belongs to the directive or declaration after it.
      if (source[i] == '@') {
        i = _annotationEnd(source, i);
        continue;
      }

      final word = _directiveWord(source, i);
      if (word == null) break;
      final isImport = word == 'import';

      final end = _directiveEnd(source, i);
      if (end < 0) break;

      if (isImport) {
        imports.add(_normaliseDirective(source.substring(i, end)));
        if (placementOpen) insertAt = _lineAfter(source, end);
        sawImport = true;
      } else if (word == 'library') {
        afterLibrary = _lineAfter(source, end);
      } else if (sawImport) {
        placementOpen = false;
      }
      i = end;
    }

    if (!sawImport && afterLibrary >= 0) insertAt = afterLibrary;

    return (insertAt: insertAt, imports: imports);
  }

  static final RegExp _identifier = RegExp(r'[A-Za-z0-9_$]+');

  static final RegExp _identifierStart = RegExp(r'[A-Za-z_$]');

  /// The directive keyword that starts at [at], or `null` when what is there is
  /// not a directive: `import` and `export` take a quoted URI (a comment may
  /// sit before it, and the space is optional, so `import'x.dart';` counts),
  /// `part` a URI or `of`, `library` a name or `;`. So `library() => 1;` and
  /// an identifier called `export` are declarations, not directives.
  static String? _directiveWord(String s, int at) {
    final word = _identifier.matchAsPrefix(s, at)?.group(0);
    if (word == null) return null;

    final after = _skipTrivia(s, at + word.length);
    final next = after < s.length ? s[after] : '';
    final quoted = next == "'" || next == '"';

    switch (word) {
      case 'import':
      case 'export':
        return quoted ? word : null;
      case 'part':
        return quoted || s.startsWith('of', after) ? word : null;
      case 'library':
        return next == ';' || _identifierStart.hasMatch(next) ? word : null;
    }
    return null;
  }

  /// Index after the annotation (`@name`, `@a.b`, `@name(args)`) at [at].
  static int _annotationEnd(String s, int at) {
    var i = at + 1;
    while (i < s.length && RegExp(r'[A-Za-z0-9_$.]').hasMatch(s[i])) {
      i++;
    }
    if (i >= s.length || s[i] != '(') return i;

    var depth = 0;
    String? quote;
    for (; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == r'\') {
          i++;
        } else if (c == quote || c == '\n') {
          quote = null;
        }
      } else if (c == "'" || c == '"') {
        quote = c;
      } else if (s.startsWith('//', i)) {
        i = _lineEnd(s, i) - 1;
      } else if (s.startsWith('/*', i)) {
        i = _blockCommentEnd(s, i) - 1;
      } else if (c == '(') {
        depth++;
      } else if (c == ')' && --depth == 0) {
        return i + 1;
      }
    }
    return s.length;
  }

  /// Index of the first character after the whitespace and comments that start
  /// at [at], or [at] itself when there are none.
  static int _skipTrivia(String s, int at) {
    var i = at;
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        i++;
      } else if (s.startsWith('//', i)) {
        i = _lineEnd(s, i);
      } else if (s.startsWith('/*', i)) {
        i = _blockCommentEnd(s, i);
      } else {
        break;
      }
    }
    return i;
  }

  /// Index of the `\n` that ends the line holding [at], or the length.
  static int _lineEnd(String s, int at) {
    final newline = s.indexOf('\n', at);
    return newline < 0 ? s.length : newline;
  }

  /// Offset of the start of the line after the one holding [at].
  static int _nextLine(String s, int at) {
    final end = _lineEnd(s, at);
    return end < s.length ? end + 1 : s.length;
  }

  /// Index after the (nested) block comment that starts at [start]; the length
  /// of [s] when it never closes.
  static int _blockCommentEnd(String s, int start) {
    var depth = 0;
    var i = start;
    while (i < s.length) {
      if (s.startsWith('/*', i)) {
        depth++;
        i += 2;
      } else if (s.startsWith('*/', i)) {
        depth--;
        i += 2;
        if (depth == 0) return i;
      } else {
        i++;
      }
    }
    return s.length;
  }

  /// Index after the `;` that ends the directive starting at [from], or -1 when
  /// there is none. A quote opens a string, so a `;` or `//` inside the URI
  /// ends nothing and starts no comment.
  static int _directiveEnd(String s, int from) {
    String? quote;
    var i = from;
    while (i < s.length) {
      final c = s[i];
      if (quote != null) {
        if (c == r'\') {
          i++;
        } else if (c == quote || c == '\n') {
          quote = null;
        }
        i++;
      } else if (c == "'" || c == '"') {
        quote = c;
        i++;
      } else if (c == ';') {
        return i + 1;
      } else if (s.startsWith('//', i)) {
        i = _lineEnd(s, i);
      } else if (s.startsWith('/*', i)) {
        i = _blockCommentEnd(s, i);
      } else {
        i++;
      }
    }
    return -1;
  }

  /// Where an import that follows the directive ending at [end] goes: the start
  /// of the next line, past a trailing comment that begins on that line (even a
  /// block comment that runs onto later ones), or, when another token such as a
  /// `part` directive shares the line, the start of that token, so the import
  /// is never written after it.
  static int _lineAfter(String s, int end) {
    var i = end;
    while (i < s.length) {
      final c = s[i];
      if (c == '\n') return i + 1;
      if (c == ' ' || c == '\t' || c == '\r') {
        i++;
      } else if (s.startsWith('//', i)) {
        return _nextLine(s, i);
      } else if (s.startsWith('/*', i)) {
        i = _blockCommentEnd(s, i);
      } else {
        return i;
      }
    }
    return s.length;
  }

  /// [text] without its comments; a block comment leaves one space, so the
  /// tokens either side of it stay apart. Strings are kept whole.
  static String _stripComments(String text) {
    final out = StringBuffer();
    String? quote;
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      if (quote != null) {
        out.write(c);
        if (c == r'\' && i + 1 < text.length) {
          out.write(text[i + 1]);
          i++;
        } else if (c == quote || c == '\n') {
          quote = null;
        }
        i++;
      } else if (c == "'" || c == '"') {
        quote = c;
        out.write(c);
        i++;
      } else if (text.startsWith('//', i)) {
        i = _lineEnd(text, i);
      } else if (text.startsWith('/*', i)) {
        out.write(' ');
        i = _blockCommentEnd(text, i);
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  /// The form two directives are compared in: comments gone, whitespace outside
  /// a string collapsed to one space, and none around `,` or before `;`. A
  /// string is kept as written, so `'a,b.dart'` and `'a;b.dart'` stay apart.
  static String _normaliseDirective(String directive) {
    final text = _stripComments(directive);
    final out = StringBuffer();
    String? quote;
    var last = '';
    var space = false;

    void write(String c) {
      out.write(c);
      last = c;
    }

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (quote != null) {
        write(c);
        if (c == r'\' && i + 1 < text.length) {
          write(text[++i]);
        } else if (c == quote || c == '\n') {
          quote = null;
        }
        continue;
      }
      if (c.trim().isEmpty) {
        space = true;
        continue;
      }
      final quoteAfterWord =
          (c == "'" || c == '"') && !space && _identifier.hasMatch(last);
      if ((space && last.isNotEmpty && last != ',' && c != ',' && c != ';') ||
          quoteAfterWord) {
        write(' ');
      }
      space = false;
      if (c == "'" || c == '"') quote = c;
      write(c);
    }
    return out.toString();
  }

  // A statement is checked in its normalised form (`import` and the URI are
  // always one space apart, none around `,` or before `;`).
  static final RegExp _importGrammar = RegExp(
    r'''^import (?:'[^'\n]*'|"[^"\n]*")'''
    r'''(?: if ?\( ?[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*'''
    r'''(?: ?== ?(?:'[^'\n]*'|"[^"\n]*"))? ?\) ?(?:'[^'\n]*'|"[^"\n]*"))*'''
    r'''(?:(?: deferred)? as [A-Za-z_$][\w$]*)?'''
    r'''(?: (?:show|hide) [A-Za-z_$][\w$]*(?:,[A-Za-z_$][\w$]*)*)*;$''',
  );

  /// [raw] without its comments, ending in a `;`.
  ///
  /// Throws [ArgumentError] unless [raw] is exactly one import directive: a
  /// second directive, an `export`, an empty statement or `import bogus;`
  /// would otherwise be dropped, written without the idempotency check, or
  /// make the file unparseable.
  static String _importStatementOf(String raw) {
    final text = raw.trim();
    if (_directiveWord(text, 0) != 'import') _throwNotOneImport(raw);

    final end = _directiveEnd(text, 0);
    if (end >= 0 && _stripComments(text.substring(end)).trim().isNotEmpty) {
      _throwNotOneImport(raw);
    }

    final code = _stripComments(end < 0 ? text : text.substring(0, end))
        .split('\n')
        .map(_tidyLine)
        .join('\n')
        .trim();

    final statement = code.endsWith(';') ? code : '$code;';
    if (!_importGrammar.hasMatch(_normaliseDirective(statement))) {
      _throwNotOneImport(raw);
    }

    return statement;
  }

  /// [line] with its indentation kept and the spaces a stripped comment left
  /// behind collapsed.
  static String _tidyLine(String line) {
    final indent = RegExp(r'^[ \t]*').stringMatch(line)!;
    final out = StringBuffer(indent);
    String? quote;
    var space = false;

    for (var i = indent.length; i < line.length; i++) {
      final c = line[i];
      if (quote != null) {
        out.write(c);
        if (c == r'\' && i + 1 < line.length) {
          out.write(line[++i]);
        } else if (c == quote) {
          quote = null;
        }
      } else if (c == ' ' || c == '\t') {
        space = true;
      } else {
        if (space) out.write(' ');
        space = false;
        if (c == "'" || c == '"') quote = c;
        out.write(c);
      }
    }
    return out.toString();
  }

  static Never _throwNotOneImport(String raw) => throw ArgumentError.value(
    raw,
    'importStatement',
    'must be exactly one import directive',
  );

  /// Insert code before the first occurrence of a pattern in a file.
  ///
  /// Does nothing if the pattern is not found.
  ///
  /// Idempotent: skips the write when `code.trim()` is already a substring of
  /// the file contents (mirrors [insertCodeAfterPattern]).
  ///
  /// Returns whether the file now carries [code]: true when it was written and
  /// true when it was already there, false only when [pattern] matched
  /// nothing. See [insertCodeAfterPattern] for why that distinction matters.
  static bool insertCodeBeforePattern({
    required String filePath,
    required Pattern pattern,
    required String code,
    Pattern? fallbackPattern,
  }) {
    final content = FileHelper.readFile(filePath);
    if (code.trim().isNotEmpty && content.contains(code.trim())) return true;
    final match =
        _firstMatch(pattern, content) ?? _firstMatch(fallbackPattern, content);

    if (match == null) return false;

    final updatedContent =
        content.substring(0, match.start) +
        code +
        content.substring(match.start);
    FileHelper.writeFile(filePath, updatedContent);

    return true;
  }

  /// Insert code after the first occurrence of a pattern in a file.
  ///
  /// Idempotent: skips the write when `code.trim()` is already a substring of
  /// the file contents. This protects re-runs of `plugin:install <name>` (and
  /// any other repeat install path) from accumulating duplicate injections.
  ///
  /// Returns whether the file now carries [code]. True when it was written and
  /// true when it was already there; false ONLY when [pattern] matched
  /// nothing.
  ///
  /// The return value exists because the absence of one was a silent failure
  /// with a measured cost. A caller could not tell an applied injection from a
  /// skipped one, so `plugin:install` reported Success over a
  /// `lib/config/app.dart` it had never touched: the plugin's provider was
  /// never registered and nothing said so.
  ///
  /// Idempotent-skip and never-matched have to stay distinguishable, or a
  /// re-run would fail on work it had already done.
  /// [fallbackPattern] is tried only when [pattern] matches nothing. It exists
  /// for the append-to-a-list shape, where the primary anchors on the LAST
  /// entry before the closing bracket and so cannot match an empty list, and
  /// the fallback anchors on the opening bracket instead. One regex with an
  /// alternation cannot express it, because `firstMatch` scans by position and
  /// the opening bracket always comes first.
  ///
  /// A populated list whose last entry the primary does not describe falls
  /// through to the fallback too, and the code then lands at the top of the
  /// list rather than the end. Correct Dart, wrong position: prefer widening
  /// the primary over relying on that.
  static bool insertCodeAfterPattern({
    required String filePath,
    required Pattern pattern,
    required String code,
    Pattern? fallbackPattern,
  }) {
    final content = FileHelper.readFile(filePath);
    if (code.trim().isNotEmpty && content.contains(code.trim())) return true;
    final match =
        _firstMatch(pattern, content) ?? _firstMatch(fallbackPattern, content);

    if (match == null) return false;

    final updatedContent =
        content.substring(0, match.end) + code + content.substring(match.end);
    FileHelper.writeFile(filePath, updatedContent);

    return true;
  }

  /// The first match of [pattern] in [content], or null when [pattern] is null
  /// or finds nothing. Accepts either `Pattern` shape the ops allow.
  static Match? _firstMatch(Pattern? pattern, String content) {
    if (pattern == null) return null;

    final RegExp regex = pattern is RegExp
        ? pattern
        : RegExp(RegExp.escape(pattern.toString()));

    return regex.firstMatch(content);
  }

  /// Create a config file with the given content.
  ///
  /// Creates parent directories if they don't exist.
  /// Overwrites the file if it already exists.
  static void createConfigFile({
    required String path,
    required String content,
  }) {
    FileHelper.writeFile(path, content);
  }
}

/// Line layout for the Dart files dowel generates into a consumer project.
///
/// A consumer that runs `dart format --set-exit-if-changed .` checks these
/// files like any other, so they must already be what the formatter writes.
/// The shapes below are the only ones the generators emit, and each lays out
/// the same under the short and the tall formatter styles.
library;

/// The formatter's page width.
const int _pageWidth = 80;

/// `<indent><head><elements><tail>` on one line when it fits the page, the
/// way the formatter collapses a short list; otherwise one element per line
/// with a trailing comma, the way it splits a long one.
///
/// [head] ends with the opening `[` and [tail] starts with the closing `]`.
List<String> listLiteralLines({
  required String head,
  required List<String> elements,
  required String tail,
  String indent = '',
}) {
  final oneLine = '$indent$head${elements.join(', ')}$tail';
  if (oneLine.length <= _pageWidth) return <String>[oneLine];

  return <String>[
    '$indent$head',
    for (final element in elements) '$indent  $element,',
    '$indent$tail',
  ];
}

/// `import '<uri>' show <name>;`, broken before `show` with a four-space
/// continuation when the line passes the page width, as the formatter does.
String importShowing(String uri, String name) {
  final oneLine = "import '$uri' show $name;";
  if (oneLine.length <= _pageWidth) return oneLine;

  return "import '$uri'\n    show $name;";
}

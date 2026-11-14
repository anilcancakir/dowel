import 'dart:io';

import 'package:path/path.dart' as p;

/// Source that still uses the package dowel replaced in 0.0.21: its import,
/// one of its `Artisan*` classes, or its `runArtisan` entry point.
final RegExp _artisanReference = RegExp(
  r'fluttersdk_artisan|\bArtisan[A-Z]\w*|\brunArtisan\b',
);

/// The files `dowel install` generates. A copy fluttersdk_artisan wrote
/// imports a package that no longer resolves, so the dispatcher that loads
/// them does not compile and `install` would skip all three as existing.
const List<String> _generatedFiles = <String>[
  'bin/dispatcher.dart',
  'lib/app/_plugins.g.dart',
  'lib/app/commands/_index.g.dart',
];

/// The generated files under [root] that fluttersdk_artisan wrote, as
/// project-relative paths. Empty for a project dowel scaffolded.
List<String> staleGeneratedFiles(String root) {
  return <String>[
    for (final relative in _generatedFiles)
      if (_referencesArtisan(File(p.join(root, relative)))) relative,
  ];
}

/// Everything under [root] left by fluttersdk_artisan, as project-relative
/// paths (a directory ends in `/`): the stale generated files, the old
/// wrappers, the old state directory, the consumer commands still written
/// against `Artisan*`, and a registry or install record naming a
/// `fluttersdk_*` package.
///
/// The `.mcp.json` entry is left to the doctor's own MCP checks, which
/// already say how to replace it.
List<String> artisanLeftovers(String root) {
  final commandsDir = Directory(p.join(root, 'lib', 'app', 'commands'));
  final installedDir = Directory(p.join(root, '.dowel', 'installed'));

  return <String>[
    ...staleGeneratedFiles(root),
    for (final wrapper in <String>['bin/fsa', 'bin/artisan.dart'])
      if (File(p.join(root, wrapper)).existsSync()) wrapper,
    if (Directory(p.join(root, '.artisan')).existsSync()) '.artisan/',
    if (commandsDir.existsSync())
      for (final file in _dartFilesIn(commandsDir))
        if (p.basename(file.path) != '_index.g.dart' &&
            _referencesArtisan(file))
          p.posix.joinAll(p.split(p.relative(file.path, from: root))),
    if (_mentionsOldPackage(File(p.join(root, '.dowel', 'plugins.json'))))
      '.dowel/plugins.json',
    if (installedDir.existsSync())
      for (final record in _sortedFiles(installedDir))
        if (p.basename(record.path).startsWith('fluttersdk_'))
          '.dowel/installed/${p.basename(record.path)}',
  ];
}

/// The migration, in the order the 0.0.21 CHANGELOG entry gives it, after
/// the [leftovers] it found.
String artisanMigrationSteps(List<String> leftovers) {
  return <String>[
    'This project still has files from fluttersdk_artisan, which dowel '
        'replaced in 0.0.21:',
    for (final leftover in leftovers) '  $leftover',
    'To migrate:',
    '  1. dart pub remove fluttersdk_artisan && dart pub add dowel, and swap '
        'each plugin for its renamed package (fluttersdk_dusk is tapir, '
        'fluttersdk_telescope is crumbs).',
    '  2. Move .artisan/ to .dowel/ and ~/.artisan/ to ~/.dowel/, then delete '
        '.dowel/plugins.json and the fluttersdk_* records under '
        '.dowel/installed/.',
    '  3. Delete bin/dispatcher.dart, bin/fsa, bin/artisan.dart, '
        'lib/app/_plugins.g.dart and lib/app/commands/_index.g.dart; in your '
        'own commands import package:dowel/dowel.dart instead of '
        'package:fluttersdk_artisan/artisan.dart and rename Artisan* classes '
        'to Dowel*.',
    '  4. dart run dowel install, then dart run dowel commands:refresh, then '
        'dart run dowel plugin:install <name> for each plugin.',
    '  5. Delete the "fluttersdk" entry from .mcp.json, then run: dart run '
        'dowel mcp:install.',
  ].join('\n');
}

bool _referencesArtisan(File file) {
  return file.existsSync() &&
      _artisanReference.hasMatch(file.readAsStringSync());
}

/// Whether the registry still names a `fluttersdk_*` package or an
/// `*ArtisanProvider` class, which its refresh would write into the barrel.
bool _mentionsOldPackage(File registry) {
  if (!registry.existsSync()) return false;
  final content = registry.readAsStringSync();

  return content.contains('fluttersdk') || content.contains('ArtisanProvider');
}

Iterable<File> _dartFilesIn(Directory dir) {
  return _sortedFiles(dir).where((file) => file.path.endsWith('.dart'));
}

List<File> _sortedFiles(Directory dir) {
  return dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

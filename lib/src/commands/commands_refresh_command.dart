import 'dart:io';

import 'package:path/path.dart' as p;

import '../console/dowel_command.dart';
import '../console/dowel_context.dart';
import '../console/command_boot.dart';
import '../helpers/cli_bundle_cache.dart';
import '../helpers/file_helper.dart';
import 'commands_index_writer.dart';

/// `dowel commands:refresh`: scans `lib/app/commands/` and rewrites
/// `_index.g.dart` so every DowelCommand subclass in that directory is
/// auto-registered on the next `dowel` invocation.
///
/// Run after manually adding/removing/renaming a command file (the more
/// common path is `dowel make:command Foo`, which already updates the
/// index automatically).
class CommandsRefreshCommand extends DowelCommand {
  /// [projectRoot] pins the project to scan; it defaults to the nearest
  /// `pubspec.yaml` above the working directory.
  CommandsRefreshCommand({this._projectRoot});

  final String? _projectRoot;

  @override
  String get name => 'commands:refresh';

  @override
  String get description =>
      'Rescan lib/app/commands/ and rewrite the auto-discovery index.';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  Future<int> handle(DowelContext ctx) async {
    final root = _projectRoot ?? FileHelper.findProjectRoot();
    final commandsDir = Directory(p.join(root, 'lib', 'app', 'commands'));
    final discovered = writeCommandsIndex(commandsDir);
    // The dispatcher imports the index, so the compiled bundle is stale now.
    CliBundleCache.purge(root);
    final indexPath = p.join(commandsDir.path, '_index.g.dart');
    ctx.output.success(
      'Refreshed: ${discovered.length} command(s) registered → $indexPath',
    );
    for (final c in discovered) {
      ctx.output.writeln('  - ${c.className}  (${c.fileName})');
    }
    if (discovered.isEmpty && _hasScannedFiles(commandsDir)) {
      ctx.output.warning(
        'Found .dart files in ${commandsDir.path} but no '
        '`class <Name>Command extends ...Command` declaration, so the index '
        'is empty.',
      );
    }
    return 0;
  }

  /// Whether [commandsDir] holds a file the scan reads (a `*.dart` file that
  /// does not start with `_`, the same filter `discoverCommandsInDir` applies).
  bool _hasScannedFiles(Directory commandsDir) =>
      commandsDir.listSync().whereType<File>().any((f) {
        final base = p.basename(f.path);
        return base.endsWith('.dart') && !base.startsWith('_');
      });
}

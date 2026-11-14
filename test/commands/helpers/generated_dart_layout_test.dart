import 'dart:convert';
import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:dowel/src/commands/commands_index_writer.dart';
import 'package:dowel/src/commands/plugins_refresh_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('generated files under a narrower formatter page width', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('dowel_layout_width_');
      File(p.join(root.path, 'pubspec.yaml'))
          .writeAsStringSync('name: app\nenvironment:\n  sdk: ^3.13.0\n');
      File(p.join(root.path, 'analysis_options.yaml'))
          .writeAsStringSync('formatter:\n  page_width: 50\n');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('pass dart format --set-exit-if-changed', () async {
      // 1. The barrel, regenerated from a registry with one plugin: its
      //    import fits 80 columns and not 50.
      File(p.join(root.path, '.dowel', 'plugins.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode(<String, dynamic>{
            'version': 1,
            'plugins': <Map<String, String>>[
              <String, String>{
                'name': 'tapir',
                'providerImport': 'package:tapir/cli.dart',
                'providerClass': 'TapirDowelProvider',
                'registeredAt': '2026-05-18T09:00:00.000Z',
              },
            ],
          }),
        );
      Directory(p.join(root.path, 'lib', 'app')).createSync(recursive: true);
      final refreshed = await PluginsRefreshCommand(projectRoot: root.path)
          .handle(DowelContext.bare(MapInput(const {}), BufferedOutput()));
      expect(refreshed, 0);

      // 2. The commands index, over a command whose list entry fits 80
      //    columns and not 50.
      final commands = Directory(p.join(root.path, 'lib', 'app', 'commands'))
        ..createSync(recursive: true);
      File(p.join(commands.path, 'greet_command.dart')).writeAsStringSync(
        'class GreetEveryoneCommand extends DowelCommand {}\n',
      );
      writeCommandsIndex(commands);

      // 3. The initial copies `install` writes from the stubs.
      final stubs = Directory(p.join(root.path, 'stubs'))..createSync();
      for (final name in <String>[
        'consumer_plugins_g.dart',
        'consumer_commands_index_initial.dart',
      ]) {
        File(p.join(stubs.path, name)).writeAsStringSync(StubLoader.load(name));
      }

      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'format',
        '--output=none',
        '--set-exit-if-changed',
        p.join(root.path, 'lib', 'app', '_plugins.g.dart'),
        p.join(commands.path, '_index.g.dart'),
        stubs.path,
      ], workingDirectory: root.path);

      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    });
  });
}

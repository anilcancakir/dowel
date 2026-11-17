import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:dowel/src/commands/commands_refresh_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CommandsRefreshCommand', () {
    final cmd = CommandsRefreshCommand();

    test('declares name commands:refresh', () {
      expect(cmd.name, 'commands:refresh');
    });

    test('declares CommandBoot.none (no VM Service required)', () {
      expect(cmd.boot, CommandBoot.none);
    });

    test('description mentions rescan + index', () {
      expect(cmd.description, contains('Rescan'));
      expect(cmd.description, contains('index'));
    });

    test('extends DowelCommand', () {
      expect(cmd, isA<DowelCommand>());
    });
  });

  group('CommandsRefreshCommand.handle()', () {
    late Directory project;
    late Directory commandsDir;

    setUp(() {
      project = Directory.systemTemp.createTempSync('commands_refresh_');
      File(p.join(project.path, 'pubspec.yaml'))
          .writeAsStringSync('name: probe\n');
      commandsDir = Directory(p.join(project.path, 'lib', 'app', 'commands'))
        ..createSync(recursive: true);
    });

    tearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });

    Future<String> refresh() async {
      final output = BufferedOutput();
      final code = await CommandsRefreshCommand(projectRoot: project.path)
          .handle(DowelContext.bare(MapInput(const {}), output));
      expect(code, 0);
      return output.content;
    }

    const warningMarker = 'class <Name>Command extends';

    test(
      'warns when a file holds no class <Name>Command extends ...Command',
      () async {
        // `Greet` extends DowelCommand but does not end in `Command`, so the
        // scan skips it.
        File(p.join(commandsDir.path, 'greet.dart')).writeAsStringSync(
          "import 'package:dowel/dowel.dart';\n"
          'class Greet extends DowelCommand {}\n',
        );

        final output = await refresh();

        expect(output, contains('0 command(s) registered'));
        expect(output, contains(warningMarker));
        expect(output, contains('index is empty'));
      },
    );

    test('does not warn when the directory holds no command file', () async {
      File(p.join(commandsDir.path, '_index.g.dart')).writeAsStringSync('');

      final output = await refresh();

      expect(output, contains('0 command(s) registered'));
      expect(output, isNot(contains(warningMarker)));
    });

    test('does not warn when a command is registered', () async {
      File(p.join(commandsDir.path, 'sync_command.dart')).writeAsStringSync(
        "import 'package:dowel/dowel.dart';\n"
        'class SyncCommand extends DowelCommand {}\n',
      );

      final output = await refresh();

      expect(output, contains('1 command(s) registered'));
      expect(output, isNot(contains(warningMarker)));
    });

    test(
      'deletes the build stamp so the next ./bin/dowel call rebuilds',
      () async {
        final dowelDir = Directory(p.join(project.path, '.dowel'))
          ..createSync();
        final stamp = File(p.join(dowelDir.path, 'build.stamp'))
          ..writeAsStringSync('deadbeef:3.4.0');

        await refresh();

        expect(stamp.existsSync(), isFalse);
      },
    );
  });
}

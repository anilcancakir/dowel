import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:dowel/src/commands/make_command_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('MakeCommandCommand', () {
    test('metadata: name=make:command, boot=none', () {
      final command = MakeCommandCommand();

      expect(command.name, 'make:command');
      expect(command.boot, CommandBoot.none);
      expect(command.description, isNotEmpty);
    });

    test('declares the canonical stub name + default namespace', () {
      final command = MakeCommandCommand();

      expect(command.getStub(), 'dowel_command');
      expect(command.getDefaultNamespace(), 'lib/app/commands');
    });

    test('dowel_command stub asset ships with the substrate', () {
      // Regression guard: make:command resolves stub by name via StubLoader's
      // 4-tier resolution. If the asset is missing from assets/stubs/, every
      // make:command invocation crashes with a FileSystemException at scaffold
      // time. The 'dowel_command' stub MUST ship in the publish archive.
      final stub = StubLoader.load('dowel_command');

      expect(stub, isNotEmpty);
      // Required placeholders driven by DowelGeneratorCommand.buildClass
      // (_replaceClass + _replaceNamespace) and MakeCommandCommand.getReplacements.
      expect(stub, contains('{{ className }}'));
      expect(stub, contains('{{ namespace }}'));
      expect(stub, contains('{{ commandName }}'));
      // The rendered output must subclass DowelCommand.
      expect(stub, contains('DowelCommand'));
    });

    test('inherits from DowelGeneratorCommand', () {
      final command = MakeCommandCommand();

      expect(command, isA<DowelGeneratorCommand>());
    });

    test('getPath composes the default namespace + snake-cased file name', () {
      final command = _ProjectRootOverride();

      final filePath = command.getPath('SyncMonitors');

      expect(
        filePath,
        p.join(command.fakeRoot, 'lib/app/commands', 'sync_monitors.dart'),
      );
    });

    test('getPath honors nested name segments', () {
      final command = _ProjectRootOverride();

      final filePath = command.getPath('Admin/Cleanup');

      expect(
        filePath,
        p.join(command.fakeRoot, 'lib/app/commands', 'admin', 'cleanup.dart'),
      );
    });
  });

  group('MakeCommandCommand.handle() in a consumer app', () {
    test(
      'rewrites the index, deletes the build stamp and keeps the bundle',
      () async {
        final project = Directory.systemTemp.createTempSync('dowel_mkc_run_');
        addTearDown(() {
          if (project.existsSync()) project.deleteSync(recursive: true);
        });
        File(p.join(project.path, 'pubspec.yaml'))
            .writeAsStringSync('name: probe\n');
        // The stub loader falls back to `<cwd>/assets/stubs`, so seed the stub
        // the zoned working directory will look in.
        File(p.join(project.path, 'assets', 'stubs', 'dowel_command.stub'))
          ..createSync(recursive: true)
          ..writeAsStringSync(StubLoader.load('dowel_command'));
        final dowelDir = Directory(p.join(project.path, '.dowel'))
          ..createSync();
        final stamp = File(p.join(dowelDir.path, 'build.stamp'))
          ..writeAsStringSync('deadbeef:3.4.0');
        final bundle = File(
          p.join(dowelDir.path, 'cli-bundle', 'bundle', 'bin', 'dispatcher'),
        )..createSync(recursive: true);
        final ctx = DowelContext.bare(
          MapInput(const {}, positional: const ['Foo']),
          BufferedOutput(),
        );

        final code = await IOOverrides.runZoned(
          () => MakeCommandCommand().handle(ctx),
          getCurrentDirectory: () => Directory(project.path),
        );

        expect(code, 0);
        final index = File(
          p.join(project.path, 'lib', 'app', 'commands', '_index.g.dart'),
        ).readAsStringSync();
        expect(index, contains('FooCommand()'));
        expect(stamp.existsSync(), isFalse);
        expect(bundle.existsSync(), isTrue);
      },
    );
  });
}

class _ProjectRootOverride extends MakeCommandCommand {
  _ProjectRootOverride() {
    fakeRoot = Directory.systemTemp.createTempSync('dowel_mkc_').path;
  }

  late String fakeRoot;

  @override
  String getProjectRoot() => fakeRoot;
}

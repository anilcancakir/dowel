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
}

class _ProjectRootOverride extends MakeCommandCommand {
  _ProjectRootOverride() {
    fakeRoot = Directory.systemTemp.createTempSync('dowel_mkc_').path;
  }

  late String fakeRoot;

  @override
  String getProjectRoot() => fakeRoot;
}

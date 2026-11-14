import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:test/test.dart';

void main() {
  group('LogsCommand', () {
    late Directory tempHome;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('dowel_logs_');
      StateFile.debugHomeOverride = tempHome.path;
    });

    tearDown(() async {
      StateFile.debugHomeOverride = null;
      if (tempHome.existsSync()) {
        await tempHome.delete(recursive: true);
      }
    });

    test('metadata: name=logs, boot=none', () {
      final command = LogsCommand();

      expect(command.name, 'logs');
      expect(command.boot, CommandBoot.none);
      expect(command.description, isNotEmpty);
    });

    test('returns 1 with warning when log file missing', () async {
      final command = LogsCommand();
      final output = BufferedOutput();
      final ctx = DowelContext.bare(MapInput(const {}), output);

      final code = await command.handle(ctx);

      expect(code, 1);
      expect(output.content, contains('Log file not found'));
    });

    test('configure registers --follow / -f flag', () {
      final command = LogsCommand();
      final parser = ArgParser();

      command.configure(parser);

      expect(parser.options.containsKey('follow'), isTrue);
    });

    test('non-follow path returns 0 when log file present', () async {
      final command = LogsCommand();
      final stateDir = Directory('${tempHome.path}/.dowel');
      stateDir.createSync(recursive: true);
      File('${stateDir.path}/flutter-dev.log').writeAsStringSync('hello');

      final output = BufferedOutput();
      final ctx = DowelContext.bare(
        MapInput(const {'follow': false}),
        output,
      );

      final code = await command.handle(ctx);

      expect(code, 0);
    });

    test('non-follow path writes the log through ctx.output, not stdout',
        () async {
      final stateDir = Directory('${tempHome.path}/.dowel')
        ..createSync(recursive: true);
      File('${stateDir.path}/flutter-dev.log')
          .writeAsStringSync('line one\nline two\n');
      final output = BufferedOutput();
      final out = _CapturingStdout();

      final code = await IOOverrides.runZoned(
        () =>
            LogsCommand().handle(DowelContext.bare(MapInput(const {}), output)),
        stdout: () => out,
      );

      expect(code, 0);
      expect(output.content, 'line one\nline two\n');
      expect(out.buffer.toString(), isEmpty);
    });

    test('follow path writes whole lines through ctx.output, not stdout',
        () async {
      final stateDir = Directory('${tempHome.path}/.dowel')
        ..createSync(recursive: true);
      final log = File('${stateDir.path}/flutter-dev.log')
        ..writeAsStringSync('line one\npartial');
      final output = BufferedOutput();
      final out = _CapturingStdout();

      // Follow never returns; tearDown deletes the log, which ends the loop
      // with an error this zone absorbs.
      runZonedGuarded(
        () => IOOverrides.runZoned(
          () => LogsCommand().handle(
            DowelContext.bare(MapInput(const {'follow': true}), output),
          ),
          stdout: () => out,
        ),
        (_, __) {},
      );
      await _waitFor(() => output.content.isNotEmpty);
      log.writeAsStringSync(' line\n', mode: FileMode.append);
      await _waitFor(() => output.content.contains('partial'));

      // A line split across two reads arrives once, unbroken.
      expect(output.content, 'line one\npartial line\n');
      expect(out.buffer.toString(), isEmpty);
    });
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within 5s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// File-private [Stdout] fake that buffers every write for assertion.
class _CapturingStdout implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  Encoding encoding = systemEncoding;

  @override
  String lineTerminator = '\n';

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String sep = '']) =>
      buffer.writeAll(objects, sep);

  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);

  @override
  void add(List<int> data) => buffer.write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> flush() => Future<void>.value();

  @override
  Future<void> get done => Future<void>.value();

  @override
  Future<void> close() => Future<void>.value();

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  int get terminalColumns => 80;

  @override
  int get terminalLines => 24;

  @override
  IOSink get nonBlocking => this;
}

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../console/dowel_command.dart';
import '../console/dowel_context.dart';
import '../console/command_boot.dart';
import '../state/state_file.dart';

/// Print or tail the captured `flutter run` stdout/stderr log.
class LogsCommand extends DowelCommand {
  @override
  String get name => 'logs';

  @override
  String get description => 'Print or --follow the captured flutter run log.';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  void configure(ArgParser parser) {
    parser.addFlag('follow', abbr: 'f', defaultsTo: false, negatable: false);
  }

  @override
  Future<int> handle(DowelContext ctx) async {
    // The log lives beside the state file, in this project's session
    // directory. An app started by an older dowel wrote it to the shared
    // `~/.dowel/` instead, so fall back there rather than reporting no
    // log for a run that has one.
    final sessionLog =
        File('${File(StateFile.path).parent.path}/flutter-dev.log');
    final logFile = sessionLog.existsSync()
        ? sessionLog
        : File('${StateFile.homeDir}/flutter-dev.log');
    if (!logFile.existsSync()) {
      ctx.output.warning(
        'Log file not found at ${logFile.path}. Run `dowel start` first.',
      );
      return 1;
    }
    // Every write goes through ctx.output: under `mcp:serve` stdout is the
    // JSON-RPC channel, and a raw write there corrupts the protocol stream
    // while the tool result comes back empty.
    final follow = (ctx.input.option('follow') as bool?) ?? false;
    if (!follow) {
      _writeLines(ctx, await logFile.readAsString());
      return 0;
    }
    int pos = 0;
    // Bytes after the last newline read so far. Output is line-based, so a
    // line split across two reads is held back until it is complete. A
    // newline byte never occurs inside a UTF-8 sequence, so splitting there
    // cannot cut a character in half.
    final pending = <int>[];
    while (true) {
      final size = logFile.lengthSync();
      if (size > pos) {
        final raf = await logFile.open();
        await raf.setPosition(pos);
        pending.addAll(await raf.read(size - pos));
        await raf.close();
        pos = size;
        final lastNewline = pending.lastIndexOf(0x0A);
        if (lastNewline >= 0) {
          _writeLines(
            ctx,
            utf8.decode(pending.sublist(0, lastNewline + 1),
                allowMalformed: true),
          );
          pending.removeRange(0, lastNewline + 1);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  // Writes `text` as-is: `writeln` adds the final newline, so the one the
  // log already ends with is dropped first.
  void _writeLines(DowelContext ctx, String text) {
    if (text.isEmpty) return;
    ctx.output.writeln(
      text.endsWith('\n') ? text.substring(0, text.length - 1) : text,
    );
  }
}

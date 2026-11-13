import 'package:args/args.dart';

import '../console/dowel_command.dart';
import '../console/dowel_context.dart';
import '../console/dowel_registry.dart';
import '../console/command_boot.dart';
import '../helpers/console_style.dart';

/// `dowel list` — prints every registered command grouped by `:` namespace.
class ListCommand extends DowelCommand {
  ListCommand(this._registry);

  final DowelRegistry _registry;

  @override
  String get name => 'list';

  @override
  String get description =>
      'List every registered command grouped by namespace.';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  void configure(ArgParser parser) {}

  @override
  Future<int> handle(DowelContext ctx) async {
    final grouped = _registry.groupedByNamespace();
    ctx.output.writeln('');
    ctx.output.info('Available commands (${_registry.length}):');
    for (final entry in grouped.entries) {
      if (entry.key.isEmpty) {
        // Root commands first.
        for (final cmd in entry.value) {
          ctx.output.writeln('  ${cmd.name.padRight(28)} ${cmd.description}');
        }
      } else {
        ctx.output.writeln('');
        ctx.output.writeln(
          ' ${ConsoleStyle.yellow}${entry.key}${ConsoleStyle.reset}',
        );
        for (final cmd in entry.value) {
          ctx.output.writeln('  ${cmd.name.padRight(28)} ${cmd.description}');
        }
      }
    }
    return 0;
  }
}

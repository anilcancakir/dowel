import 'package:dowel/dowel.dart';
import 'commands/greet_command.dart';

/// DowelServiceProvider for awesome_plugin.
///
/// Plugin commands live in `lib/src/commands/`. Use `dart run magic:dowel
/// make:command Name` from inside the plugin directory to scaffold a new
/// command. The generator writes the command file under `lib/src/commands/`
/// AND auto-registers it in the [commands] list below (idempotent), so the
/// command surfaces immediately when the host runs `plugin:install awesome_plugin`.
class AwesomePluginDowelProvider extends DowelServiceProvider {
  @override
  List<DowelCommand> commands() => <DowelCommand>[
        GreetCommand(),
        // Commands added via `make:command` land here automatically.
      ];
}

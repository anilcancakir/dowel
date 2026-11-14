# Plugin Authoring Guide

A plugin is a Dart package that ships a `DowelServiceProvider` subclass. The
subclass declares the CLI commands and MCP tool descriptors the plugin contributes.
When a consumer calls `plugin:install <name>`, dowel registers the provider in
`lib/app/_plugins.g.dart`, which is loaded at startup and merged into the
`DowelRegistry`. Commands appear in `dowel list`; MCP tool descriptors surface
through the stdio JSON-RPC server so LLM agents can invoke them by name.

- [Getting Started](#getting-started)
- [DowelServiceProvider Contract](#dowelserviceprovider-contract)
- [Public surface](#public-surface)
- [Writing Commands](#writing-commands)
- [Adding MCP Tools](#adding-mcp-tools)
- [Publishing](#publishing)
- [Linking from a Consumer](#linking-from-consumer)
- [Related Documentation](#related-documentation)

---

<a name="getting-started"></a>
## Getting Started

Scaffold the plugin skeleton with the `make:plugin` command:

```bash
dart run dowel make:plugin awesome_plugin
```

The generator creates the following tree inside `awesome_plugin/`:

```
awesome_plugin/
  lib/
    awesome_plugin.dart          # barrel export
    src/
      awesome_plugin_dowel_provider.dart   # DowelServiceProvider subclass
      commands/                              # one file per DowelCommand
  pubspec.yaml                   # declares dowel dependency
  CHANGELOG.md
  README.md
```

The generated provider is immediately wirable: `plugin:install awesome_plugin`
injects `AwesomePluginDowelProvider.new` into the consumer's `_plugins.g.dart`.

---

<a name="dowelserviceprovider-contract"></a>
## DowelServiceProvider Contract

Every plugin must extend `DowelServiceProvider`
(`lib/src/console/dowel_service_provider.dart:11-25`):

```dart
abstract class DowelServiceProvider {
  /// Human-readable provider name used in collision error messages.
  /// Defaults to the runtime class name.
  String get providerName => runtimeType.toString();

  /// Returns the commands this provider contributes to the application.
  List<DowelCommand> commands();

  /// Returns the MCP tool descriptors this provider contributes.
  ///
  /// Defaults to an empty list so existing providers compile without
  /// modification. Override to expose VM-Service-backed tools to the MCP
  /// server.
  List<McpToolDescriptor> mcpTools() => const <McpToolDescriptor>[];
}
```

Key points:

- `commands()` is **abstract**: return every `DowelCommand` subclass your
  plugin ships. Duplicate command names throw `DowelCommandCollisionException`.
- `mcpTools()` defaults to an empty list. Override it to expose VM Service
  extension tools to the MCP server.
- `providerName` defaults to `runtimeType.toString()`. Override it with a
  stable identifier (e.g. `'tapir'`) so collision messages survive
  class renames.
- There is no `register()` lifecycle hook on `DowelServiceProvider`.
  Initialisation belongs in command constructors or the host app's boot phase.

Minimal scaffold provider (`assets/stubs/make_plugin/generic/provider.dart.stub`):

```dart
import 'package:dowel/dowel.dart';

final class AwesomePluginDowelProvider extends DowelServiceProvider {
  @override
  List<DowelCommand> commands() => <DowelCommand>[
        // Commands added via `make:command` land here automatically.
      ];
  // To expose MCP tools, override mcpTools() returning your descriptor list.
}
```

### Public surface

Everything a plugin needs comes from `package:dowel/dowel.dart`, whose exports list their symbols with `show` (the install manifest model and the install operation classes are exported whole): what is not listed is internal and may change in a minor release. Most builtin command classes (`DoctorCommand`, `ListCommand`, `PluginInstallCommand` and the rest) and `McpServer` are not part of it; the ones a plugin runs or builds on are (`StartCommand`, `StopCommand`, `RestartCommand`, `HotRestartCommand`, `InstallDowelCommand`, `MakeFastCliCommand` and `TinkerCommand`). `package:args` is re-exported only for `ArgParser`, `ArgParserException` and `ArgResults`; import `package:args` for anything else.

Only the classes a plugin builds on are open to `extends`: `DowelCommand`, `DowelGeneratorCommand`, `DowelInstallCommand`, `DowelServiceProvider`, `DowelContext`, `DowelOutput` and `VmServiceClient`. Every other exported class is `final`, and `DowelInput`, `PromptDriver`, `StubDriver` and `VirtualFs` are `interface` classes: a test fake implements them. A fake of `InMemoryFs` or `DowelRegistry` implements `VirtualFs` or builds the registry instead of extending it.

---

<a name="writing-commands"></a>
## Writing Commands

Each entry in `commands()` is a `DowelCommand` subclass. Declare the command
surface via the Signature DSL or `configure(ArgParser)`:

- **Signature DSL** (preferred): `String get signature => 'cmd:name {arg} {--flag}'`.
  See [Signature DSL reference](../reference/signature-dsl.md) for the full syntax.
- **`configure(ArgParser)`**: explicit fallback for cases the DSL cannot express
  (subcommands, allowed values with validation, etc.).

Scaffold a new command inside the plugin directory:

```bash
dart run dowel make:command MyVerb
```

The generator writes `lib/src/commands/my_verb_command.dart` and auto-registers
it in the provider's `commands()` list. See
[make:command](../commands/index.md) for the full scaffold walkthrough.

---

<a name="adding-mcp-tools"></a>
## Adding MCP Tools

Override `mcpTools()` and return a `List<McpToolDescriptor>`. Each descriptor
(`lib/src/mcp/mcp_tool_descriptor.dart:24-82`) is a `const`-constructible value
with four required fields:

| Field | Type | Purpose |
|:---|:---|:---|
| `name` | `String` | Snake-case, service-prefixed tool name (e.g. `awesome_start`). Must be globally unique across all loaded providers. |
| `description` | `String` | Action-oriented, LLM-targeted description. Imperative opening sentence, usage bullets, constraint-forward language. |
| `inputSchema` | `Map<String, dynamic>` | JSON Schema draft-7 object describing accepted input. Pass `{'type': 'object', 'properties': {}}` when the tool takes no arguments. |
| `extensionMethod` | `String` | VM Service extension registered in the running Flutter isolate (e.g. `ext.awesome.start`). Internal routing key; not included in the MCP wire shape. |

Example provider with commands and MCP tools:

```dart
import 'package:dowel/dowel.dart';

final class AwesomeStartCommand extends DowelCommand {
  @override
  String get signature => 'awesome:start';

  @override
  String get description => 'Start the awesome service.';

  @override
  CommandBoot get boot => CommandBoot.connected;

  @override
  Future<int> handle(DowelContext context) async {
    context.output.success('Awesome service started.');
    return 0;
  }
}

final class AwesomeStopCommand extends DowelCommand {
  @override
  String get signature => 'awesome:stop';

  @override
  String get description => 'Stop the awesome service.';

  @override
  CommandBoot get boot => CommandBoot.connected;

  @override
  Future<int> handle(DowelContext context) async {
    context.output.success('Awesome service stopped.');
    return 0;
  }
}

final class AwesomePluginDowelProvider extends DowelServiceProvider {
  @override
  List<DowelCommand> commands() => [
        AwesomeStartCommand(),
        AwesomeStopCommand(),
      ];

  @override
  List<McpToolDescriptor> mcpTools() => [
        McpToolDescriptor(
          name: 'awesome_start',
          description: 'Start the awesome service',
          inputSchema: {'type': 'object', 'properties': {}},
          extensionMethod: 'ext.awesome.start',
        ),
      ];
}
```

`extensionMethod` must match the `registerExtension` call in the running Flutter
isolate; the descriptor is not callable without it.

The MCP server collects descriptors from all loaded providers when
`runDowel(collectMcpTools: true)` fires (`bin/mcp.dart` sets this
automatically). Tool names must be unique; a collision throws
`DowelMcpToolCollisionException` at startup.

Naming convention: prefix every tool name with a short service identifier
followed by an underscore (for example `my_plugin_greet`). The prefix should
match the package's `providerName` (or a recognisable abbreviation thereof).

---

<a name="publishing"></a>
## Publishing

1. Bump the version in `pubspec.yaml` following SemVer (patch for fixes, minor
   for new commands/tools, major for breaking provider API changes).

2. Declare the dependency on `dowel` with a caret constraint, not
   `path:`. `dart pub add dowel` writes one.

3. Validate the archive before tagging:

   ```bash
   dart pub publish --dry-run
   ```

4. Add a CHANGELOG entry, then publish:

   ```bash
   dart pub publish
   ```

---

<a name="linking-from-consumer"></a>
## Linking from Consumer

The consumer installs the plugin with:

```bash
dart run dowel plugin:install awesome_plugin
```

This registers `AwesomePluginDowelProvider.new` in `lib/app/_plugins.g.dart` and
re-generates the barrel; the provider is discovered at the next `dowel start`.
See [plugin:install](../commands/plugin-install.md) for the two routing modes
(manifest, direct registration).

---

<a name="related-documentation"></a>
## Related Documentation

- [install-yaml.md](install-yaml.md) - `install.yaml` manifest schema for
  declaring install steps declaratively.
- [installer-dsl.md](installer-dsl.md) - `PluginInstaller` fluent DSL for
  authoring programmatic install logic.
- [make:plugin](../commands/make-plugin.md) - scaffold command reference with
  all flags and the generated file tree.

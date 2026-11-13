# Quickstart

A 5-step walkthrough taking a fresh Dart or Flutter project from zero to a working
dowel setup with a plugin installed and a custom command registered.

- [1. Install and scaffold](#1-install-and-scaffold)
- [2. Add a custom command](#2-add-a-custom-command)
- [3. Install a plugin](#3-install-a-plugin)
- [4. Start a Flutter app (optional)](#4-start-a-flutter-app-optional)
- [5. List everything wired](#5-list-everything-wired)
- [What's next?](#whats-next)
- [Related Documentation](#related-documentation)

Prerequisites: Dart 3.4+ SDK, a Flutter project with a valid `pubspec.yaml`, and
`flutter pub get` already run so `.dart_tool/package_config.json` is present.

---

<a name="1-install-and-scaffold"></a>
## 1. Install and scaffold

Add `dowel` to your project dependencies, then run `install`
to write the canonical wrapper files. The scaffold is idempotent: re-running it when
the files already exist is a safe no-op (pass `--force` to overwrite).

```bash
dart pub add dowel
dart run dowel install
```

The scaffold writes three files:

- `bin/dispatcher.dart`: the CLI entry point you will invoke for every subsequent
  `dart run :dispatcher` call (or `./bin/dowel <cmd>` once the AOT bundle is built).
- `lib/app/_plugins.g.dart`: codegen barrel that wires registered plugin providers
  into the consumer wrapper automatically.
- `lib/app/commands/_index.g.dart`: codegen barrel that auto-discovers commands
  under `lib/app/commands/` so `dart run dowel list` picks them up without
  manual registration.

After scaffolding, run commands with `./bin/dowel` or `dart run dowel`; both
delegate to the consumer wrapper `bin/dispatcher.dart`, which loads your
commands and plugins.

---

<a name="2-add-a-custom-command"></a>
## 2. Add a custom command

Generate a command scaffold under `lib/app/commands/`. The name argument is
normalised: `HelloWorld` becomes class `HelloWorldCommand` with signature
`hello-world`. The codegen barrel is refreshed automatically so the command appears
on the next `dowel list` without an extra step.

```bash
dart run dowel make:command HelloWorld
```

The generator creates `lib/app/commands/hello_world_command.dart` with a skeleton
`handle` method and a pre-filled `signature` string. Edit the file to implement
your command logic, then run `dart run dowel hello-world` to invoke it.

If you are authoring a plugin (a `lib/src/<name>_dowel_provider.dart` exists at
the project root) the generator writes to `lib/src/commands/` instead and injects
the import and registration line into the provider file automatically.

---

<a name="3-install-a-plugin"></a>
## 3. Install a plugin

Add the plugin package to your `pubspec.yaml` and resolve it, then register it with
the consumer wrapper via `plugin:install`. The command runs a two-stage resolution:

1. When the plugin ships an `install.yaml` manifest, the manifest flow runs: ops are
   parsed, conflict-checked, and committed atomically, then the plugin's
   `DowelServiceProvider` is registered in `.dowel/plugins.json` and
   `lib/app/_plugins.g.dart` is refreshed.
2. When no manifest is found but the canonical scaffold (`lib/app/_plugins.g.dart`)
   is present, registration writes directly to `.dowel/plugins.json` and refreshes
   the codegen barrel (no `bin/dispatcher.dart` edit needed). Without the
   scaffold the command stops and asks you to run `dart run dowel install`.

```bash
dart pub add awesome_plugin
dart run dowel plugin:install awesome_plugin
```

After installation the plugin's commands appear in `dart run dowel list`, under the
heading of the prefix before the `:` in their names. Pass `--dry-run` to preview every write operation before it
commits. Pass `--use-yaml-only` to error out instead of falling back when no
`install.yaml` is found.

---

<a name="4-start-a-flutter-app-optional"></a>
## 4. Start a Flutter app (optional)

If your project ships a Flutter app, `start` boots `flutter run` in a detached
process and writes a per-project session with the VM Service URI. The session file
is what lets MCP clients and hot-reload/hot-restart commands locate the running
instance without you providing the URI each time.

```bash
dart run dowel start --device=chrome
```

The default target is `chrome`. Pass `--device=macos` (or any Flutter device
identifier) for desktop or mobile targets. The command scrapes the VM Service URI
from the flutter run output, normalises it to a `ws://` WebSocket address, and
writes the full state (PID, VM URI, web port, device, project root) to this
project's session at `~/.dowel/sessions/<hash>/state.json`. Sessions are per
project, so a second app can be driven at the same time without either
overwriting the other.

Once the state file is present, `reload`, `hot-restart`, `logs`, and `stop` all
resolve the running process automatically from the file without extra flags.

---

<a name="5-list-everything-wired"></a>
## 5. List everything wired

Verify the full command registry by running `list`. The output is grouped by `:`
namespace: commands without a `:` come first with no heading, and each `:` prefix
(built-in or plugin-contributed) gets its own section.

```bash
dart run dowel list
```

A clean setup shows the 22 built-in commands: 12 without a namespace (`start`,
`stop`, `status`, `logs`, `restart`, `reload`, `hot-restart`, `doctor`, `list`,
`help`, `install`, `tinker`) listed first, then the namespaced ones under the
headings `commands`, `make`, `mcp`, `plugin` and `plugins`. Your `hello-world`
command appears among the commands without a namespace, and a plugin's commands
appear under the heading of the prefix before the `:` in their names.

---

<a name="whats-next"></a>
## What's next?

- Browse the full [command catalogue](../commands/index.md) to see what each builtin does.
- Wire the MCP server into your AI client via [MCP setup](../mcp/setup.md).
- Write your own plugin via the [plugin authoring guide](../plugins/authoring.md).

---

All five commands shown above are part of the `dowel` built-in command
set and require no additional packages beyond the initial `dart pub add` in step 1.
Plugin commands contributed by third-party packages appear in `dowel list` under
their own namespace after `plugin:install` completes.

<a name="related-documentation"></a>
## Related Documentation

- [Installation](installation.md): requirements and the project scaffold.
- [Plugin Authoring](../plugins/authoring.md): write a plugin of your own.

# Commands

Catalogue of every user-facing command shipped by `dowel`, grouped by intent.

Every command is invoked as `dart run dowel <name>`, or as `./bin/dowel <name>` once the project has run `install` (the fast wrapper). Commands are auto-discovered through the registered providers list; nothing wires by hand.

Need a quick reminder of what a command does without leaving the terminal? Run `dart run dowel list` for the full registry grouped by namespace, or `dart run dowel help <name>` for the per-command flag surface. This page exists for the deeper view: the boot mode, the MCP exposure, and the grouping rationale.

- [How to read this page](#how-to-read-this-page)
- [Naming conventions](#naming-conventions)
- [Lifecycle](#lifecycle)
- [Scaffolding](#scaffolding)
- [Plugin management](#plugin-management)
- [MCP](#mcp)
- [Introspection](#introspection)
- [Code generation](#code-generation)
- [Featured deep-dives](#featured-deep-dives)
- [Boot mode at a glance](#boot-mode-at-a-glance)
- [Related Documentation](#related-documentation)

<a name="how-to-read-this-page"></a>
## How to read this page

Each group section ships a single table with four columns:

- **Command** is the canonical name you type after `dart run dowel` (or `./bin/dowel`).
- **Description** is a one-line summary of the command, drawn from the `description` getter that `dart run dowel list` prints (reworded here where the getter's wording has fallen behind the behaviour, for example the `~/.dowel/state.json` path it still names for `start` and `stop`).
- **Boot Mode** is the `CommandBoot` value the dispatcher reads before invoking `handle()` (see `lib/src/console/command_boot.dart`). `none` means pure CLI: no Flutter binding, no VM Service connection. `connected` means the command dials this project's session and fails fast if no app is running.
- **MCP Tool** is the canonical `dowel_*` tool name surfaced over stdio JSON-RPC by `mcp:serve`, or the literal `no` when the command is not in the substrate allowlist. The allowlist lives in `lib/src/mcp/mcp_server.dart` (`_safeDowelCommandNames`) and intentionally omits `help`, codegen, installer, and MCP-meta commands.

<a name="naming-conventions"></a>
## Naming conventions

Two shapes appear in the catalogue:

- Single word (`start`, `stop`, `status`, `logs`, `restart`, `reload`, `hot-restart`, `doctor`, `tinker`, `help`, `list`, `install`) for top-level actions on the substrate.
- Namespaced `<group>:<verb>` (`make:plugin`, `make:command`, `make:fast-cli`, `plugin:install`, `plugin:uninstall`, `plugins:refresh`, `mcp:serve`, `mcp:install`, `mcp:uninstall`, `commands:refresh`) for actions scoped to a subsystem.

`hot-restart` is a single word that happens to contain a hyphen: it lives in the lifecycle group and is not namespaced, so `list` prints it among the commands without a heading. It sends the `R` keypress to `flutter run`.

<a name="lifecycle"></a>
## Lifecycle

The commands that own the running Flutter process: spawn, stop, query, tail, restart, reload, hot-restart. All run pure CLI; none of them boot Flutter or Magic in the dowel process. State lives in a per-project session directory under `~/.dowel/sessions/`, written by `start` and consumed by everything that needs the VM Service URI. `~/.dowel/state.json` remains a pointer to whichever session started last. Any command that acts on the recorded app refuses when the session belongs to another project, so a `stop` from the wrong checkout cannot kill a sibling's run.

All of them are also surfaced as MCP tools. Together with `list`, `doctor` and `tinker` from the [Introspection](#introspection) group they make up the MCP tools of the substrate, the agent-facing surface area. `dowel_start` and `dowel_restart` take every option their CLI commands take; see the [MCP Tool Reference](../mcp/tool-reference.md).

| Command | Description | Boot Mode | MCP Tool |
|:---|:---|:---|:---|
| `start` | Boot `flutter run -d <device>` detached and record the VM Service URI to this project's session. | none | dowel_start |
| `stop` | Stop the running flutter app's whole process group, wait until it and its web port are gone, and delete this project's session. | none | dowel_stop |
| `status` | Print JSON status of the recorded flutter app. | none | dowel_status |
| `logs` | Print or `--follow` the captured flutter run log. | none | dowel_logs |
| `restart` | Stop and start the running flutter app; carries the prior session's device, web port, VM Service port, CDP port, `--flutter-arg` values and profile build mode across. | none | dowel_restart |
| `reload` | Hot reload the running app (sends `r` to flutter run's stdin). State preserved. | none | dowel_reload |
| `hot-restart` | Hot restart the running app (sends `R` to flutter run's stdin). Drops Dart state, keeps process. | none | dowel_hot_restart |

<a name="scaffolding"></a>
## Scaffolding

Commands that write source files into the consumer project. They are deliberately excluded from the MCP allowlist: source mutation is better routed through the client's own file tools, and the stub system uses placeholder substitution (`{{ name }}`, `{{ pascalName }}`, `{{ commandPrefix }}`) that benefits from interactive prompts.

| Command | Description | Boot Mode | MCP Tool |
|:---|:---|:---|:---|
| `make:plugin` | Scaffold a new dowel plugin skeleton. | none | no |
| `make:command` | Scaffold a new DowelCommand subclass under `lib/app/commands/` (or `lib/src/commands/` when run inside a plugin). | none | no |
| `make:fast-cli` | Scaffold the POSIX `bin/dowel` wrapper and pre-compile the AOT cache under `.dowel/cli-bundle/` for a startup of tens of milliseconds; `.gitignore` gets only the cache entries. | none | no |
| `install` | Scaffold the canonical native Flutter consumer wrapper (`bin/dispatcher.dart` plus `lib/app/_plugins.g.dart` plus `lib/app/commands/_index.g.dart`) and chain `make:fast-cli` in-process. It stops and lists what to delete when a generated file still comes from `fluttersdk_artisan`; see [Migrating from fluttersdk_artisan](../getting-started/migrating-from-fluttersdk-artisan.md). | none | no |

<a name="plugin-management"></a>
## Plugin management

Commands that maintain the `.dowel/plugins.json` registry and its generated barrel `lib/app/_plugins.g.dart`. Commit `.dowel/plugins.json` and `.dowel/installed/`: a fresh clone without the registry makes `plugin:install` refuse to run rather than regenerate the barrel with one plugin. The registry and the generated barrels are written atomically (`.tmp` plus rename), so concurrent readers (editors, lint daemons) never observe partial state; an install's editor-backed edits (dependencies, injections, native files) write directly and are not rolled back. `plugin:install` routes through two modes (manifest, direct registration) depending on whether the plugin ships an `install.yaml`.

| Command | Description | Boot Mode | MCP Tool |
|:---|:---|:---|:---|
| `plugin:install` | Register a third-party dowel plugin (`install.yaml` manifest preferred; direct registration into the dowel scaffold otherwise). | none | no |
| `plugin:uninstall` | Uninstall a third-party dowel plugin (reverses the files and dependencies its install record lists; see [plugin:install](plugin-install.md#reversibility)). | none | no |
| `plugins:refresh` | Regenerate `lib/app/_plugins.g.dart` from `.dowel/plugins.json` registry. | none | no |

<a name="mcp"></a>
## MCP

`mcp:serve` runs the dowel MCP server, and `mcp:install` and `mcp:uninstall` wire it into a host like Claude Code, Cursor, or Windsurf. The `mcp:*` meta commands recurse into the server and are intentionally excluded from the allowlist. Per-tool visibility is configured via `.dowel/mcp.json`, environment variables, and CLI flags (the three layers compose Cargo-style: file plus env plus flags, with deny rules always winning).

| Command | Description | Boot Mode | MCP Tool |
|:---|:---|:---|:---|
| `mcp:serve` | Run the dowel MCP server (stdio JSON-RPC) for Claude Code, Cursor, Windsurf. | none | no |
| `mcp:install` | Add the dowel MCP server entry to `.mcp.json` (idempotent; preserves other server entries). | none | no |
| `mcp:uninstall` | Remove the dowel MCP server entry from `.mcp.json` (preserves other entries). | none | no |

<a name="introspection"></a>
## Introspection

Commands that observe the substrate or its host. `tinker` is the only command in the catalogue with `CommandBoot.connected`: it dials the running app's VM Service. It is still exposed as `dowel_tinker` (its `--eval` one-shot path drives the MCP tool; a blank `--eval` is a usage error, never the REPL); `help` is the one command here outside the MCP allowlist.

`doctor` runs its checks, then prints advisory warnings that never change the exit code: a stale `.mcp.json` entry, a Flutter SDK too old for the CDP commands, and the files a project moved from `fluttersdk_artisan` still carries. It hands over to the project's `bin/dispatcher.dart` when there is one, so run it after deleting an old generated dispatcher; see [Migrating from fluttersdk_artisan](../getting-started/migrating-from-fluttersdk-artisan.md#what-dowel-detects).

| Command | Description | Boot Mode | MCP Tool |
|:---|:---|:---|:---|
| `help` | Show detailed help for a single command. | none | no |
| `list` | List every registered command grouped by namespace. | none | dowel_list |
| `doctor` | Run environment preflight checks (flutter, dart, port availability). | none | dowel_doctor |
| `tinker` | Connected REPL into the running Flutter app (Dart expression evaluation via VM Service). | connected | dowel_tinker |

<a name="code-generation"></a>
## Code generation

One command that rewrites the `lib/app/commands/_index.g.dart` barrel. Codegen sits in its own bucket because the consumer rarely runs it by hand: `make:command` and `plugin:install` invoke it as a follow-up step. The generated barrel is never edited manually; the source of truth is the set of `*_command.dart` files under `lib/app/commands/`. `commands:refresh` does not rebuild the compiled `bin/dowel`: delete `.dowel/build.stamp` (the next `./bin/dowel` call rebuilds) or use `dart run :dispatcher <command>` to see a new command at once.

| Command | Description | Boot Mode | MCP Tool |
|:---|:---|:---|:---|
| `commands:refresh` | Rescan `lib/app/commands/` and rewrite the auto-discovery index. | none | no |

<a name="boot-mode-at-a-glance"></a>
## Boot mode at a glance

`CommandBoot` has two values, `none` and `connected`. Only `tinker` is `CommandBoot.connected`, because its job is to evaluate Dart expressions against a live VM Service isolate; every other command runs with `CommandBoot.none`. Everything else (lifecycle commands included) shells out to `flutter run` or operates on disk; the dowel process itself never depends on a Flutter binding.

This separation is what lets the substrate ship as a pure-Dart package: the framework itself stays runtime-free, and a plugin's connected commands reach the app through the VM Service.

<a name="featured-deep-dives"></a>
## Featured deep-dives

These commands earn their own pages because their flags, modes, or composition rules outgrow a single table row:

- [start](start.md)
- [plugin:install](plugin-install.md)
- [mcp:serve](mcp-serve.md)
- [make:plugin](make-plugin.md)
- [make:fast-cli](make-fast-cli.md)
- [install](install.md)
- [tinker](tinker.md)

Slug rule: the deep-dive URL drops the `:` separator in favour of `-`, so `plugin:install` lives at `commands/plugin-install/`, `mcp:serve` at `commands/mcp-serve/` and `make:fast-cli` at `commands/make-fast-cli/`. The remaining commands share this index page; reach for `dart run dowel help <name>` for their full flag surface.

<a name="related-documentation"></a>
## Related Documentation

- [Getting Started](../getting-started/index.md): what dowel is and how the pieces fit.
- [MCP Tool Reference](../mcp/tool-reference.md): the substrate tools these commands map to.
- [Signature DSL](../reference/signature-dsl.md): how a command declares its arguments and flags.

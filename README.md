<p align="center">
  <img src="https://raw.githubusercontent.com/anilcancakir/dowel/master/.github/dowel-logo.svg" width="120" alt="Dowel logo" />
</p>

<h1 align="center">Dowel</h1>

<p align="center">
  <strong>One binary for your Flutter dev loop and your AI agent.</strong><br/>
  Start, hot reload and inspect a running app, scaffold code, install plugins transactionally, and hand the same commands to your agent through a built-in MCP server.
</p>

<p align="center">
  <a href="https://pub.dev/packages/dowel"><img src="https://img.shields.io/pub/v/dowel.svg" alt="pub package"></a>
  <a href="https://github.com/anilcancakir/dowel/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/anilcancakir/dowel/ci.yml?branch=master&label=CI" alt="CI"></a>
  <a href="https://codecov.io/gh/anilcancakir/dowel"><img src="https://codecov.io/gh/anilcancakir/dowel/graph/badge.svg" alt="codecov"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://pub.dev/packages/dowel/score"><img src="https://img.shields.io/pub/points/dowel" alt="pub points"></a>
</p>

<p align="center">
  <a href="https://anilcancakir.com/dowel">Documentation</a> ·
  <a href="https://pub.dev/packages/dowel">pub.dev</a> ·
  <a href="https://github.com/anilcancakir/dowel/issues">Issues</a>
</p>

## At a glance

| Fact | Value |
|---|---|
| Package | [`dowel`](https://pub.dev/packages/dowel) |
| Install | `dart pub add dowel`, then `dart run dowel install` |
| Import | `package:dowel/dowel.dart` |
| Entry points | `dart run dowel <command>`, `./bin/dowel`, `runDowel`, `DowelCommand`, `DowelServiceProvider`, `PluginInstaller`, `./bin/dowel mcp:serve` or `dart run :dispatcher mcp:serve` (substrate and plugin tools), `dart run dowel:mcp` (substrate tools only) |
| Platforms | macOS and Linux for the lifecycle commands (`start`, `stop`, `reload`, ...); the rest of the CLI and the MCP server run wherever Dart does |
| Requires | Dart >=3.13, Flutter for the app you drive |
| Dependencies | `args`, `dart_mcp`, `vm_service`, `yaml_edit`, `xml`, `crypto`, `path`, `meta`, `stream_channel`, `yaml` |
| License | MIT |

## Install

```bash
dart pub add dowel
dart run dowel install
```

`install` writes `bin/dispatcher.dart` (the entry that calls `runDowel`), the codegen barrels `lib/app/_plugins.g.dart` and `lib/app/commands/_index.g.dart`, and builds the fast wrapper `bin/dowel` (about 100 ms to start, against about 3 s for `dart run`). Run it again and it skips every file that already exists (`--force` overwrites them) and keeps the `dowel` constraint your pubspec already has: `install` adds `dowel: ^<running version>` only when the pubspec declares none. It adds only the machine-local cache to `.gitignore` (`.dowel/cli-bundle/`, `.dowel/build.stamp` and `.dowel/.dowel.lock/`), so commit `.dowel/plugins.json` and `.dowel/installed/`.

Moving an app from `fluttersdk_artisan`? `install` stops on the files that package generated and prints what to delete and the commands to run; `doctor` warns about the same leftovers. The steps are in [Migrating from fluttersdk_artisan](https://anilcancakir.com/dowel/docs/getting-started/migrating-from-fluttersdk-artisan).

```bash
dart run dowel list      # every registered command, grouped by namespace
dart run dowel doctor    # preflight: Flutter and Dart on PATH, the default port
```

## Run the app under supervision

`start` launches `flutter run` detached and records the session per project under `~/.dowel/sessions/<hash>/`, so two apps can be driven at once and a command never acts on another project's app.

```bash
dart run dowel start --device=chrome
dart run dowel reload          # hot reload, Dart state kept
dart run dowel hot-restart     # hot restart, Dart state dropped
dart run dowel logs --follow
dart run dowel stop
```

| Command | Effect |
|---|---|
| `start`, `stop`, `restart` | Launch, tear down and relaunch the app; `stop` reaps the process group |
| `reload`, `hot-restart` | Send `r` and `R` to the detached `flutter run` through a FIFO |
| `status`, `logs` | Print the recorded session as JSON; print or follow the captured log |
| `tinker` | A REPL (or `--eval`) that evaluates Dart in the running app over the VM Service |

A command that dials the running app (`tinker` among them) exits `75` while the app is still building, so a script can retry; any other non-zero code is a real failure.

## Add a command

`make:command Greet` scaffolds the class and registers it in the nearest provider. The signature string declares the arguments and flags:

```dart
import 'package:dowel/dowel.dart';

final class GreetCommand extends DowelCommand {
  @override
  String get signature => 'greet {name} {--shout}';

  @override
  String get description => 'Greet a person by name.';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  Future<int> handle(DowelContext context) async {
    final name = context.input.argument('name') ?? 'world';
    final greeting = 'Hello, $name';
    context.output.success(
      context.input.option('shout') == true ? greeting.toUpperCase() : greeting,
    );
    return 0;
  }
}
```

A command that the signature cannot express overrides `configure(ArgParser)` instead. Two providers registering the same command name fail at boot with `DowelCommandCollisionException`.

## Install plugins

```bash
dart pub add awesome_plugin
dart run dowel plugin:install awesome_plugin --dry-run   # preview every operation
dart run dowel plugin:install awesome_plugin
```

A plugin describes its install footprint in an `install.yaml` manifest, or in code with the `PluginInstaller` DSL when it needs branching. Either way the installer stages every operation and writes nothing until the commit, writes through a `.tmp` file and a rename, skips what is already in place, and records each applied operation under `.dowel/installed/<plugin>.json`, so `plugin:uninstall` can reverse it. The reversal removes the files an install wrote, the dependencies it added and the plugin's registry entry; a dependency the project already declared stays, and edits injected into existing files (`InjectImport`, `InjectAfterPattern`) are logged as skipped, so remove those by hand. An install record written by an older dowel is refused until `plugin:install <name> --force` rewrites it, and `plugin:install` refuses to run when `lib/app/_plugins.g.dart` registers providers but `.dowel/plugins.json` is missing: restore it from version control.

| Piece | Where it lives |
|---|---|
| Manifest: files to copy, provider and config wiring, Android, iOS, macOS and web edits, env vars, prompts | `install.yaml` in the plugin package |
| Procedural escape hatch: `writeFile`, `injectImport`, `injectProvider`, `injectAndroidPermission`, `injectEnvVar`, ... | `DowelInstallCommand` subclass driving `PluginInstaller` |
| The plugin's commands | A `DowelServiceProvider` exported from `package:<name>/cli.dart` |

A plugin without a manifest is registered directly in `.dowel/plugins.json` and needs the scaffold from `dowel install`. `make:plugin <name>` generates a plugin package with all of this wired.

## Give your agent the MCP server

```bash
./bin/dowel mcp:install      # or: dart run dowel mcp:install
```

`mcp:install` writes the `dowel` entry into `.mcp.json`; reconnect your client once (Claude Code: `/mcp reconnect dowel`). The server speaks stdio JSON-RPC and exposes the substrate tools plus whatever the installed plugins contribute:

| Tool | Does |
|---|---|
| `dowel_start`, `dowel_stop`, `dowel_restart` | Run the app lifecycle |
| `dowel_reload`, `dowel_hot_restart` | Apply a code change to the running app |
| `dowel_status`, `dowel_logs`, `dowel_doctor`, `dowel_list` | Read the session, the log (returned in the tool result), the toolchain and the command list |
| `dowel_tinker` | Evaluate a Dart expression in the running app; a blank `eval` is a usage error |

`dowel_start` and `dowel_restart` take every option their CLI commands take. Without a running app the server stays up with the substrate tools and reconnects on the next call that needs the VM Service, after the app restarts too. A filter (`.dowel/mcp.json`, then `DOWEL_MCP_*` variables, then `mcp:serve` flags) allows or denies tools and packages; a deny wins at every layer.

## Commands

| Namespace | Commands |
|---|---|
| Lifecycle | `start`, `stop`, `status`, `logs`, `restart`, `reload`, `hot-restart` |
| Scaffolding | `install`, `make:plugin`, `make:command`, `make:fast-cli` |
| Plugin management | `plugin:install`, `plugin:uninstall`, `plugins:refresh` |
| MCP | `mcp:serve`, `mcp:install`, `mcp:uninstall` |
| Introspection | `help`, `list`, `doctor`, `tinker` |
| Codegen | `commands:refresh` |

## For AI coding agents

Rules for an agent working with this package. Each one is a mistake the maintainers already made once.

| Do | Because |
|---|---|
| Run `dart run dowel install` once before `plugin:install` for a plugin without an `install.yaml` | The command registers into `lib/app/_plugins.g.dart` and stops without it |
| Preview with `plugin:install <name> --dry-run` before the real run | File writes swap in through `.tmp` files after staging, but dependency and injection edits write directly and are not rolled back (a failed install then reports `rolledBack: false` and leaves a partial record), and a conflict with a user-edited file needs a decision |
| Commit `.dowel/plugins.json` and `.dowel/installed/`; ignore only `.dowel/cli-bundle/`, `.dowel/build.stamp` and `.dowel/.dowel.lock/` | The registry regenerates `lib/app/_plugins.g.dart`; without it on a fresh clone `plugin:install` refuses to run |
| Leave `*.g.dart` barrels alone; regenerate with `commands:refresh` and `plugins:refresh` | They are generated, a hand edit is overwritten |
| Start the app with `dowel start`, not `flutter run` | Reload, restart, logs and tinker find the app through the recorded session |
| In a git worktree, run `dowel start` there (or pass `--state=<path>`) before any command that uses the session (`reload`, `stop`, `tinker`, a plugin's `<package>:*`) | The ownership check passes when the worktree sits inside the project root the main app recorded (an app at the repo root, the worktree under it) and for state with no recorded `projectRoot`; the command then acts on the main app and reports success. A sibling checkout, or an app in a subdirectory the worktree is not inside, is refused. MCP plugin tools and `dowel_tinker` run no such check. An MCP server resolves the session from its own working directory and falls back to the shared `~/.dowel/state.json` pointer when that project has none, so it can reach the main app; run these from a shell inside the worktree. `--state=<path>` skips the check, and a missing or unreadable file falls back to that pointer, so confirm the file exists and holds the intended `projectRoot` |
| Reconnect the MCP client after `mcp:install` or a change to `.dowel/mcp.json` | Clients do not reload a server entry on their own |
| Use `./bin/dowel mcp:serve` (or `dart run :dispatcher mcp:serve`) for plugin tools | `dart run dowel:mcp` loads only the substrate tools |
| Read the exit code: `75` means retry, anything else non-zero is a failure | The app may still be building |
| Never treat `bin/dowel.dart` as a project wrapper | It is this package's own entry point; the wrapper is `bin/dispatcher.dart` |

## Dependencies

`dart_mcp` for the MCP server, `vm_service` for the connection to the running app, `args` for command-line parsing, `yaml` and `yaml_edit` for manifests and in-place edits, `xml` for Android and Apple platform files, `crypto` for the install-record hashes. Dowel itself is pure Dart; the app you drive needs Flutter.

## Links

- [Documentation](https://anilcancakir.com/dowel/docs/getting-started/installation): installation, quickstart, [migrating from fluttersdk_artisan](https://anilcancakir.com/dowel/docs/getting-started/migrating-from-fluttersdk-artisan), every command, MCP setup, plugin authoring and the signature DSL
- [API reference](https://pub.dev/documentation/dowel/latest/)
- [llms.txt](llms.txt) and the [agent skill](skills/dowel/SKILL.md) for AI coding agents: `npx skills add anilcancakir/dowel`
- [Changelog](CHANGELOG.md)
- [Report an issue](https://github.com/anilcancakir/dowel/issues)
- [Security policy](SECURITY.md)

## License

MIT, see [LICENSE](LICENSE). Built by [Anılcan Çakır](https://anilcancakir.com).

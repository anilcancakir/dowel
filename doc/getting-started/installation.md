# Installation

Getting started with dowel requires a few steps to wire the CLI binary and codegen scaffolding into your project.

- [Requirements](#requirements)
- [Installation](#installation-step)
- [Basic Setup](#basic-setup)
- [Verify Installation](#verify-installation)
- [Related Documentation](#related-documentation)

<a name="requirements"></a>
## Requirements

Before adding dowel to your project, ensure your environment meets these minimum version requirements. We recommend staying on the latest stable Dart SDK for the best experience.

dowel is a pure Dart package. Flutter is optional: it is only required when you intend to drive a running Flutter app (hot reload, Tapir gestures, Crumbs inspection). Projects that only need scaffolding, code generation, or the MCP server can run on any Dart 3.4+ environment.

| Dependency | Minimum Version | Recommended |
|:---|:---|:---|
| Dart       | `>= 3.4.0`      | `3.6.0+`    |
| Flutter    | optional        | `3.27.0+`   |

<a name="installation-step"></a>
## Installation

Add `dowel` to your project using the Dart CLI:

```bash
dart pub add dowel
```

Alternatively, add it manually to your `pubspec.yaml`:

```yaml
dependencies:
  dowel: ^0.0.20
```

Then fetch dependencies:

```bash
dart pub get
```

<a name="basic-setup"></a>
## Basic Setup

After installing the package, run the scaffold command to create the canonical consumer wrapper in your project:

```bash
dart run dowel install
```

This command writes three files into your project:

| File | Purpose |
|:---|:---|
| `bin/dispatcher.dart` | The runnable entry point. `dart run :dispatcher <cmd>` (or `./bin/dowel <cmd>` once the AOT bundle is built) dispatches here. |
| `lib/app/_plugins.g.dart` | Generated plugin provider list. Updated by `plugin:install` and `plugins:refresh`. |
| `lib/app/commands/_index.g.dart` | Generated command index. Updated by `make:command` and `commands:refresh`. |

The command is idempotent: re-running it skips files that already exist. Pass `--force` to overwrite:

```bash
dart run dowel install --force
```

### Dependency injection into pubspec.yaml

`install` also ensures `dowel` is listed as a direct dependency in your `pubspec.yaml`. The generated barrel files at `lib/app/_plugins.g.dart` and `lib/app/commands/_index.g.dart` import from `package:dowel/dowel.dart`, so the analyzer requires a direct dep to pass `depend_on_referenced_packages`.

The injection is automatic and follows two modes:

- **Monorepo / path-dep workflow**: when your project already resolves `dowel` via a local path (detected from `.dart_tool/package_config.json`), the scaffold injects a `path:` reference pointing to the same checkout. This avoids a pub.dev fetch against a version that may not yet be published.
- **pub.dev workflow**: when no local resolution is found, the scaffold injects the `any` constraint and lets pub resolve the version transitively. Replace `any` with a pinned range (e.g. `^0.0.20`) before committing.

<a name="verify-installation"></a>
## Verify Installation

Run the built-in `list` command to confirm the scaffold is wired correctly:

```bash
dart run dowel list
```

The output lists all registered commands grouped by the part of the name before the `:`. Commands without a `:` (`start`, `install`, `tinker` and the rest) print first, with no heading; the namespaced commands follow under one heading per prefix, in alphabetical order. A fresh scaffold with no additional plugins shows the 22 built-in commands:

```
 ℹ Available commands (22):
  doctor                       Run environment preflight checks (flutter, dart, port availability).
  help                         Show detailed help for a single command.
  hot-restart                  Hot restart the running app (sends `R` to flutter run's stdin). Drops Dart state, keeps process.
  install                      Scaffold the canonical Flutter consumer (bin/dispatcher.dart + barrels) and install bin/dowel fast-CLI.
  list                         List every registered command grouped by namespace.
  logs                         Print or --follow the captured flutter run log.
  reload                       Hot reload the running app (sends `r` to flutter run's stdin). State preserved.
  restart                      Stop + start the running flutter app.
  start                        Boot `flutter run -d <device>` detached and record the VM Service URI to this project's session.
  status                       Print JSON status of the recorded flutter app.
  stop                         Stop the running flutter app and delete this project's session.
  tinker                       Connected REPL into the running Flutter app (Dart expression evaluation via VM Service).

 commands
  commands:refresh             Rescan lib/app/commands/ and rewrite the auto-discovery index.

 make
  make:command                 Scaffold a new DowelCommand subclass under lib/app/commands/ (or lib/src/commands/ when run inside a plugin).
  make:fast-cli                Scaffold a fast-CLI wrapper (bin/dowel) plus AOT-compiled dowel binary, giving local invocations a ~50ms startup vs ~3s with dart run.
  make:plugin                  Scaffold a new dowel plugin skeleton.

 mcp
  mcp:install                  Add the dowel MCP server entry to .mcp.json (idempotent; preserves other server entries).
  mcp:serve                    Run the dowel MCP server (stdio JSON-RPC) for Claude Code / Cursor / Windsurf.

After editing .dowel/mcp.json or env vars, run /mcp reconnect dowel in Claude Code to apply the changes.
  mcp:uninstall                Remove the dowel MCP server entry from .mcp.json (preserves other entries).

 plugin
  plugin:install               Register a third-party dowel plugin (install.yaml manifest preferred; direct registration into the dowel scaffold otherwise).
  plugin:uninstall             Uninstall a third-party dowel plugin (reverses the install manifest).

 plugins
  plugins:refresh              Regenerate lib/app/_plugins.g.dart from .dowel/plugins.json registry.
```

The stray paragraph under `mcp:serve` is that command's two-paragraph description printed as written. If the list prints without errors, the installation is complete.

<a name="related-documentation"></a>
## Related Documentation

- [Quickstart](quickstart.md): a first command, a plugin and the MCP server.
- [Commands](../commands/index.md): what each built-in command does.
- [MCP Setup](../mcp/setup.md): wire the server into an AI client.

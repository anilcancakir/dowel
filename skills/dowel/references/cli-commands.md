# CLI-only commands

The substrate MCP tools cover the app lifecycle and inspection. Every other builtin is CLI-only and runs from a shell: `help`, `install`, `make:command`, `make:fast-cli`, `make:plugin`, `commands:refresh`, `plugins:refresh`, `plugin:install`, `plugin:uninstall`, `mcp:serve`, `mcp:install`, `mcp:uninstall`. Flags and defaults are in `./bin/dowel help <cmd>` and `<cmd> --help`; this file holds what that output does not say. Unknown options exit 1 and print help.

## Contents

- [Picking the shell form](#picking-the-shell-form)
- [install](#install)
- [make:command](#makecommand)
- [make:fast-cli](#makefast-cli)
- [make:plugin](#makeplugin)
- [commands:refresh and plugins:refresh](#commandsrefresh-and-pluginsrefresh)
- [plugin:install](#plugininstall)
- [plugin:uninstall](#pluginuninstall)
- [mcp:serve, mcp:install and mcp:uninstall](#mcpserve-mcpinstall-and-mcpuninstall)

## Picking the shell form

| Form | Use when |
|---|---|
| `./bin/dowel <cmd>` | The AOT wrapper exists (after `install`). Native start; it rebuilds itself when stale, see `state-and-recovery.md` |
| `dart run :dispatcher <cmd>` | `./bin/dowel` is unavailable (Windows, fresh clone, broken cache); plugin commands load |
| `dart run dowel <cmd>` | Before `install`, or to debug the substrate. It hands over to `bin/dispatcher.dart` when the project has one, except `commands:refresh` and `plugins:refresh`, which run in-process |

## install

Scaffolds the consumer: `bin/dispatcher.dart`, `lib/app/_plugins.g.dart` and `lib/app/commands/_index.g.dart` (both barrels start empty), adds `dowel` to `pubspec.yaml`, then chains `make:fast-cli` so `./bin/dowel` is ready. Existing files are skipped (`Skipped (exists)`); `--force` rewrites them. Files are written directly, not through a `.tmp` swap. Exit 1 when `pubspec.yaml` has no `name:`; otherwise the exit code of `make:fast-cli`.

## make:command

`make:command <Name>` writes `lib/app/commands/<snake_name>_command.dart` and refreshes `_index.g.dart` without printing it. Inside a plugin package (detected from the pubspec name) it writes under `lib/src/commands/` and registers the class in the plugin's provider instead. Exit 1 when the name is missing or the file exists; `--force` overwrites. The command name derives from the class name (`SyncMonitors` becomes `sync-monitors`, `Admin/UserSync` becomes `admin:user-sync`).

## make:fast-cli

Wires `bin/dowel` and compiles the AOT bundle. It stops before compiling when `bin/dowel` already exists, unless `--force` is passed. Exit 1 when `pubspec.yaml` or `bin/dispatcher.dart` is missing.

## make:plugin

`make:plugin <name>` scaffolds a plugin package (default `packages/<name>`, or `--target`/`--path`) and runs `flutter create`. The name must start with a lowercase letter and use `[a-z0-9_]`. `--magic` adds the Magic variant (`install.yaml`, Magic dependencies, a Magic-style install command) and more files; `--bootstrap-command` renames the install sub-command. Authoring the plugin itself is in the plugin authoring docs.

## commands:refresh and plugins:refresh

- `commands:refresh` rescans `lib/app/commands/*.dart` (files starting with `_` are skipped), lists each class it found and rewrites `_index.g.dart`. It does not purge the AOT bundle.
- `plugins:refresh` rewrites `lib/app/_plugins.g.dart` from `.dowel/plugins.json` through a `.tmp` swap, prints `Refreshed N plugin(s)` and purges the AOT bundle. A non-identifier `providerClass` is refused.
- Neither delegates to the project wrapper. Failures such as a missing `lib/app` exit 3.

## plugin:install

`plugin:install <name>` needs the package in `pubspec.yaml` and resolvable through `.dart_tool/package_config.json`. It reads `install.yaml` from the package root or `assets/install.yaml` and runs the manifest route (staged operations, an install record, then registration). Without a manifest it registers the plugin straight into `.dowel/plugins.json`, which needs the scaffold from `install`; `--use-yaml-only` turns that case into an error, and `--bootstrap-command=<cmd>` chains the plugin's own install sub-command.

- `--dry-run` prints `DRY RUN -- would execute N operations` and writes nothing.
- `--force` bypasses the conflict check (a user-edited file the plan would overwrite). Without it a conflict exits 2.
- Exit 1 on an error or an invalid manifest; success prints `Success: applied N ops; record at <path>`. On the manifest route a failed provider registration or bootstrap command only warns and the exit stays 0: read the output and run the missed step by hand: when the plugin is missing from `.dowel/plugins.json`, add its entry first, then run `plugins:refresh` for the barrel.
- File operations swap in through `.tmp` files after every one was staged. Editor-backed operations (dependency additions, the `Inject*` operations) write directly while staging and are not rolled back, so after a failed install inspect `git status` and recover by hand.

## plugin:uninstall

Needs the install record `.dowel/installed/<name>.json` and the plugin still in `pubspec.yaml`. A plugin registered by the direct route has no record, so uninstall refuses it. It reverses the recorded file-creating operations (`WriteFile`, `PublishFile`, `CopyFile`) and dependency additions, skips everything else (each `Inject*`, `DeleteFile`) with one warning naming how many, then drops the plugin from `.dowel/plugins.json` and regenerates the barrel. Remove the skipped edits by hand. `--dry-run` previews; it prompts unless `--force` or `--non-interactive`. Answering no exits 0; a conflict exits 2.

## mcp:serve, mcp:install and mcp:uninstall

- `mcp:serve` blocks on stdin serving stdio JSON-RPC and exits 0 when the client disconnects. Plugin tools load only through the dispatcher (`./bin/dowel mcp:serve` or `dart run :dispatcher mcp:serve`); the filter flags `--include-package`, `--exclude-package`, `--include-tool` and `--exclude-tool` are described in `mcp-tools.md`.
- `mcp:install [--path] [--invocation]` is idempotent and always rewrites the `dowel` entry in `.mcp.json`, keeping other servers; the entry shape is in `state-and-recovery.md`. A stale `fluttersdk` server entry left by the old package is reported, not removed. Reconnect the client afterwards.
- `mcp:uninstall [--path]` removes only the `dowel` entry; a missing file or entry is a warning and exit 0.

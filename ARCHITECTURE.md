# dowel architecture

## Overview

dowel is a command framework plus a substrate that drives a running Flutter app. `bin/dowel.dart` and `bin/mcp.dart` both call `runDowel`, which builds a `DowelRegistry` (builtin commands, then plugin providers); `DowelApplication` dispatches. A consumer project re-enters the same core through its own generated wrapper, which is how plugin commands and MCP tools get in. A command that declares `CommandBoot.connected` receives a `VmServiceClient` for the app that `StateFile` locates. The installer is a separate subsystem: a DSL that only enqueues operations, a transaction that executes them, and editors that touch consumer files.

## Codemap

### `lib/src/console/`

- Owns: dispatch (`runDowel`, `DowelApplication`), the registry, the signature DSL, `DowelServiceProvider`.
- Must not: import `commands/` outside `run_dowel.dart`, the single place builtins are listed (`_builtinCommands`); check with `rg -ln "import '\.\./commands" lib/src/console`.
- Depends on: `mcp/` for tool descriptors only; `state/` and `vm/` for connected commands.

### `lib/dowel.dart`

- Owns: the public surface plugins compile against. Its exports list their symbols with `show`, except `install_manifest.dart` and `install_operation.dart`, which are exported whole (the manifest model and the sealed operation hierarchy).
- Must not: export a symbol a plugin neither extends nor calls, or an exported concrete class that is not `final`. Only `DowelCommand`, `DowelGeneratorCommand`, `DowelInstallCommand`, `DowelServiceProvider`, `DowelContext`, `DowelOutput` and `VmServiceClient` stay open to `extends`; `DowelInput`, `PromptDriver`, `StubDriver` and `VirtualFs` are `interface` classes. `package:args` is re-exported only for `ArgParser`, `ArgParserException` and `ArgResults`.

### `lib/src/installer/` and `lib/src/helpers/`

- Owns: `PluginInstaller` (enqueues, never writes), `InstallTransaction` (the only executor; it returns `InstallSuccess`, `InstallDryRun`, `InstallConflict` or `InstallError`), `ConflictDetector`, `install_record.dart` (the record format and `readInstallRecord`, which refuses what it cannot read), `ManifestInstaller` (`install.yaml` to operations), `PluginsRegistryFile`; `helpers/` holds the static editors (`ConfigEditor` and the other `*Editor` classes) that write consumer files.
- Must not: import `helpers/` from `PluginInstaller`; check with `rg -n "import '\.\./helpers" lib/src/installer/plugin_installer.dart` (no output). Editors return outcomes and the transaction decides what they mean.
- Depends on: commands also call editors directly (`install_command.dart`, `make_command_command.dart`), so an editor change is not installer-only.

### `lib/src/mcp/`

- Owns: `McpServer`, `McpToolDescriptor`, `McpFilterConfig` (file, env and CLI layers), the substrate allowlist `_safeDowelCommandNames`.
- Depends on: the registry for plugin tools, `state/` and `vm/` for the app connection (`VmServiceClient.onDone` is how the server learns the app went away).

### `lib/src/state/`

- Owns: the per-project session (state, log and FIFO under `~/.dowel/sessions/<hash>/`) and `sessionOwnershipError`; everything that needs a running app resolves it through `StateFile`.

## Invariants

| Rule | Why | Verify |
|------|-----|--------|
| Plugin MCP tools are collected only when `collectMcpTools` is set | CLI runs skip walking and validating descriptors they never use | `test/console/run_dowel_mcp_collect_test.dart` |
| `bin/mcp.dart` never delegates to a consumer wrapper | The MCP entry must serve the full substrate itself | `test/bin/mcp_main_test.dart` |
| A duplicate MCP tool name throws, never overrides | Tool names are what the model sees | `test/console/dowel_registry_mcp_tools_test.dart` |
| Denied tools never reach `registerTool`; deny beats allow and denies union across layers | A denied tool must not leak at dispatch | `test/mcp/mcp_server_test.dart`, `test/mcp/mcp_filter_config_test.dart` |
| Only names in `_safeDowelCommandNames` become `dowel_*` tools; interactive, codegen, `mcp:*` and installer commands stay out | They need a TTY or recurse into the MCP server, and an allowlist keeps a new builtin off the model surface by default | `test/mcp/mcp_server_test.dart` (`substrate commands surface as dowel_* MCP tools`) |
| `DowelApplication._runWithConnected` and the commands that read the session (`stop`, `status`, `reload`, `hot-restart`) refuse a session that belongs to another project | Without it every command succeeds against the wrong app | `test/state/session_ownership_test.dart`, `test/commands/stop_command_ownership_test.dart` |
| Two projects never share a session file | A shared slot made the second `start` hijack the first | `test/state/state_file_session_test.dart` |
| `lib/dowel.dart` lists its exports with `show`, and an exported concrete class is `final` unless plugins extend it | A symbol in the barrel is a promise to plugins; an open class makes every new method a breaking change | `rg -n "^export '[^']+';$" lib/dowel.dart` prints only `install_manifest.dart` and `install_operation.dart` |
| An install record carries `version: 1`, project-relative `stubHashes` keys and a `preExisting` flag on each dependency addition; a record without the version is refused, never read | Absolute keys tied a record to one checkout, and without the flag uninstall removed a dependency the project had before the install | `test/installer/conflict_detector_test.dart`, `test/installer/install_transaction_test.dart`, `test/installer/manifest_installer_test.dart` |
| A failure after an editor-backed edit returns `InstallError(rolledBack: false)` and writes a partial record (`"partial": true`) that keeps the ops and hashes of the record it replaces | Editors write through `dart:io` while staging, outside the `.tmp` rollback; claiming a rollback hid edits `plugin:uninstall` could not reach, and dropping the earlier record orphaned its files | `test/installer/install_transaction_test.dart` |
| `readInstallRecord` refuses a record whose `targetPath`, `sourcePath` or `stubHashes` key is absolute or leaves the project | Uninstall deletes what the record names, and the record is committed, so a pull request can point it anywhere | `test/installer/manifest_installer_test.dart` (`a record naming a path outside the project`) |
| Only the CLI cache under `.dowel/` (`cli-bundle*`, `build.stamp*`, `.dowel.lock/`; the globs cover a build's scratch paths) is gitignored; `plugins.json`, `installed/` and `mcp.json` are tracked, and `plugin:install` refuses to run when the barrel registers providers but `plugins.json` is missing | A bare `.dowel/` ignore hid the registry, so a fresh clone regenerated the barrel with one plugin and dropped the rest | `test/commands/plugin_install_command_test.dart`, `test/commands/make_fast_cli_command_test.dart` |
| A command writes through `ctx.output`, never to the process stdout; `tinker` rejects a blank `--eval` instead of starting its REPL | Under `mcp:serve` stdout is the JSON-RPC channel: raw log lines corrupted the stream, and a REPL would read the protocol from stdin | `test/commands/logs_command_test.dart`, `test/commands/tinker_command_test.dart`; `rg -n "stdout\.(write\|add)" lib/src/commands` finds only the REPL prompt |
| The MCP server registers its tools before the handshake and drops its VM client when `VmServiceClient.onDone` completes | Registering inside `initialize` sent a `list_changed` per tool ahead of the response; a dead client failed every call until the MCP client restarted | `test/mcp/mcp_server_test.dart` |

## Flows

Command dispatch (`dart run dowel <cmd>`):

1. `bin/dowel.dart` calls `runDowel` (`lib/src/console/run_dowel.dart`), which strips `--state` first (`_consumeStateFlag`).
2. When a consumer wrapper exists and the command is not in `_bypassDelegation` (`commands:refresh`, `install`, `plugins:refresh`: the commands that rewrite or replace the files the wrapper imports), it re-invokes `dart run :dispatcher <args>` and stops.
3. Otherwise it fills a `DowelRegistry` from `_builtinCommands`, `baseProviders` and `autoProviders()`; `registerMcpToolsFor` runs only with `collectMcpTools`.
4. `DowelApplication.dispatch` (`lib/src/console/dowel_application.dart`) parses with the command's `CommandSignature`, then switches on `command.boot`. `CommandBoot.connected` reads `StateFile`, runs `sessionOwnershipError`, restores `vmServiceUri` from the log when `start` was cut short (`vmServiceUriFromLog`), connects `VmServiceClient` and calls `handle`.

Plugin install to registry (`plugin:install <name>`):

1. `PluginInstallCommand.handle` (`lib/src/commands/plugin_install_command.dart`) refuses a missing `.dowel/plugins.json` while the barrel registers providers, then passes a resolvable `install.yaml` to `ManifestInstaller.install`, which translates its sections into operations on `PluginInstaller`.
2. `PluginInstaller.commit` hands them to `InstallTransaction.commit`, which checks conflicts through `ConflictDetector` against the record `readInstallRecord` returns, stages, swaps `.tmp` files in and writes the record.
3. `_registerDowelProvider` adds the plugin to `.dowel/plugins.json` (`PluginsRegistryFile.addPlugin`); `PluginsRefreshCommand` regenerates `lib/app/_plugins.g.dart` and purges `CliBundleCache`.
4. On the next run the consumer wrapper imports that barrel, and each plugin's `DowelServiceProvider` contributes `commands()` and `mcpTools()`.

MCP tool call:

1. `McpServeCommand.handle` merges `McpFilterConfig.fromFile('.dowel/mcp.json')`, `fromEnv` and `fromCli`.
2. The `McpServer` constructor builds plugin tools (`DowelRegistry.mcpTools`) plus substrate tools from `_safeDowelCommandNames`, applies the filter once and registers the survivors (`_registerTools`); `McpServer.initialize` only reads state and connects once.
3. `McpServer._dispatch` sends a `dowel:` name to `_dispatchDowelCommand`, `tapir_evaluate` to `_dispatchEvaluate`, and any other tool to `callServiceExtension`.

## Decisions

| Decision | Why | Rejected alternatives | Status |
|----------|-----|-----------------------|--------|
| Session directory per project, keyed by a SHA-256 prefix of the canonical root of the nearest `pubspec.yaml` ancestor | One global `state.json` let another project's `start` take the slot; the log and FIFO collide for the same reason | A single global file | Active |
| `~/.dowel/state.json` still written as a pointer to the last start | The recovery recipe hand-writes it and external tools read it | Dropping it | Active |
| MCP tool collection is a separate opt-in call on the registry | CLI invocations pay nothing for descriptors they never consume | Collecting inside `registerProvider` | Active |
| `dowel install` runs from the substrate and stops on generated files that still use the previous package, instead of delegating to the project's dispatcher | That dispatcher no longer compiles, so delegation failed with a compiler error | Rewriting the stale files silently | Active |

## Change guide

| To change | Touch | Also check |
|-----------|-------|------------|
| Add a builtin command | `lib/src/commands/<x>_command.dart`, `_builtinCommands` in `run_dowel.dart`; an export in `lib/dowel.dart` only when plugins run or build on it | `test/commands/<x>_command_test.dart`, `doc/commands/`; `_safeDowelCommandNames` only if the model may call it |
| Export a symbol | `lib/dowel.dart` with a `show` list; `final class` unless plugins extend it | `doc/plugins/authoring.md` (Public surface) |
| Change the install record | `install_record.dart` (bump `installRecordVersion` when an older record cannot be read), `InstallTransaction._buildRecord` | `ConflictDetector`, `ManifestInstaller.uninstall`, `PluginUninstallCommand`, `doc/plugins/installer-dsl.md` (The install record) |
| Change the signature DSL | `lib/src/console/command_signature.dart`, `dowel_command.dart` | `test/console/command_signature_test.dart`, `doc/reference/signature-dsl.md` |
| Add an `InstallOperation` | `install_operation.dart`, `InstallTransaction._stageOp` and `_serializeOp`, `DryRunRenderer.render`, `ConflictDetector._isHelperEdit` and `_targetAbsPath`, `ManifestInstaller.reverseOf` | `ManifestInstaller._opFromRecord` and `PluginUninstallCommand._opFromRecord` switch on strings, so the compiler will not flag a missing case; `doc/plugins/installer-dsl.md` |
| Add a DSL method over an existing operation | `plugin_installer.dart` | a `test/installer/plugin_installer_*_test.dart`, `doc/plugins/installer-dsl.md` |
| Add an `install.yaml` key | `install_manifest.dart`, `manifest_parser.dart`, a `ManifestInstaller._apply*` method | `doc/plugins/install-yaml.md`, `test/installer/manifest_parser_test.dart` |
| Add an editor | `lib/src/helpers/<x>_editor.dart`, a `_stageOp` arm and `_helperWrittenTargets`; export in `lib/dowel.dart` only when a plugin's own install command calls it | `test/helpers/<x>_editor_test.dart` |
| Add a substrate MCP tool | `_safeDowelCommandNames`, `_mcpDescriptionFor`, `_commandInputSchema` in `mcp_server.dart` | `test/mcp/mcp_server_test.dart`, `doc/mcp/tool-reference.md` |
| Add an MCP filter layer | `mcp_filter_config.dart` (`fromX`, `merge`, `apply`), `mcp_serve_command.dart` | `test/mcp/mcp_filter_config_test.dart`, `doc/mcp/setup.md` |
| Change the state schema | `state_file.dart` (class doc), `StartCommand.bootingState` and `readyState` | every reader: `stop`, `reload`, `hot_restart`, `restart`, `status`, `_runWithConnected`, `mcp_server.dart` |
| Add a generated consumer file | a stub in `assets/stubs/`, its writer in `lib/src/commands/` | `install_command.dart`, `assets/stubs/dispatcher.dart.stub` |

## Traps

- `McpFilterConfig.fromFile` reads `.dowel/mcp.json` relative to the working directory, not the project root: `lib/src/commands/mcp_serve_command.dart`.
- `_classPattern` in `lib/src/commands/commands_index_writer.dart` matches every `class X extends *Command` in `lib/app/commands/`, including intermediate bases and commented-out code, and each match is registered in `_index.g.dart`.
- `toolsDeny` matches the MCP name (`dowel_hot_restart`), not the command name: `lib/src/mcp/mcp_filter_config.dart`.
- `doctor` is in `_bypassDelegation` with `install`, `commands:refresh` and `plugins:refresh`: a diagnostic must run when the project's own `bin/dispatcher.dart` does not compile, which is the state of a project moving from the previous package. Keep any new check independent of the consumer's dispatcher: `lib/src/console/run_dowel.dart`.
- `PluginUninstallCommand._opFromRecord` rebuilds only `WriteFile`, `DeleteFile` and `CopyFile`, while `ManifestInstaller._opFromRecord` also rebuilds `PublishFile` and the dependency operations, so `plugin:uninstall --dry-run` lists fewer reversals than the real run performs: `lib/src/commands/plugin_uninstall_command.dart`.

Last reviewed: 2026-11-14 after the install-record review fixes (path containment, partial-record merge, cache globs).

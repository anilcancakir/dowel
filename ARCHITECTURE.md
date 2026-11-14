# dowel architecture

## Overview

dowel is a command framework plus a substrate that drives a running Flutter app. `bin/dowel.dart` and `bin/mcp.dart` both call `runDowel`, which builds a `DowelRegistry` (builtin commands, then plugin providers); `DowelApplication` dispatches. A consumer project re-enters the same core through its own generated wrapper, which is how plugin commands and MCP tools get in. A command that declares `CommandBoot.connected` receives a `VmServiceClient` for the app that `StateFile` locates. The installer is a separate subsystem: a DSL that only enqueues operations, a transaction that executes them, and editors that touch consumer files.

## Codemap

### `lib/src/console/`

- Owns: dispatch (`runDowel`, `DowelApplication`), the registry, the signature DSL, `DowelServiceProvider`.
- Must not: import `commands/` outside `run_dowel.dart`, the single place builtins are listed (`_builtinCommands`); check with `rg -ln "import '\.\./commands" lib/src/console`.
- Depends on: `mcp/` for tool descriptors only; `state/` and `vm/` for connected commands.

### `lib/src/installer/` and `lib/src/helpers/`

- Owns: `PluginInstaller` (enqueues, never writes), `InstallTransaction` (the only executor), `ManifestInstaller` (`install.yaml` to operations), `PluginsRegistryFile`; `helpers/` holds the static editors (`ConfigEditor` and the other `*Editor` classes) that write consumer files.
- Must not: import `helpers/` from `PluginInstaller`; check with `rg -n "import '\.\./helpers" lib/src/installer/plugin_installer.dart` (no output). Editors return outcomes and the transaction decides what they mean.
- Depends on: commands also call editors directly (`install_command.dart`, `make_command_command.dart`), so an editor change is not installer-only.

### `lib/src/mcp/`

- Owns: `McpServer`, `McpToolDescriptor`, `McpFilterConfig` (file, env and CLI layers), the substrate allowlist `_safeDowelCommandNames`.
- Depends on: the registry for plugin tools, `state/` and `vm/` for the app connection.

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

## Flows

Command dispatch (`dart run dowel <cmd>`):

1. `bin/dowel.dart` calls `runDowel` (`lib/src/console/run_dowel.dart`), which strips `--state` first (`_consumeStateFlag`).
2. When a consumer wrapper exists and the command is not in `_bypassDelegation`, it re-invokes `dart run :dispatcher <args>` and stops.
3. Otherwise it fills a `DowelRegistry` from `_builtinCommands`, `baseProviders` and `autoProviders()`; `registerMcpToolsFor` runs only with `collectMcpTools`.
4. `DowelApplication.dispatch` (`lib/src/console/dowel_application.dart`) parses with the command's `CommandSignature`, then switches on `command.boot`. `CommandBoot.connected` reads `StateFile`, runs `sessionOwnershipError`, restores `vmServiceUri` from the log when `start` was cut short (`vmServiceUriFromLog`), connects `VmServiceClient` and calls `handle`.

Plugin install to registry (`plugin:install <name>`):

1. `PluginInstallCommand.handle` (`lib/src/commands/plugin_install_command.dart`) passes a resolvable `install.yaml` to `ManifestInstaller.install`, which translates its sections into operations on `PluginInstaller`.
2. `PluginInstaller.commit` hands them to `InstallTransaction.commit`.
3. `_registerDowelProvider` adds the plugin to `.dowel/plugins.json` (`PluginsRegistryFile.addPlugin`); `PluginsRefreshCommand` regenerates `lib/app/_plugins.g.dart` and purges `CliBundleCache`.
4. On the next run the consumer wrapper imports that barrel, and each plugin's `DowelServiceProvider` contributes `commands()` and `mcpTools()`.

MCP tool call:

1. `McpServeCommand.handle` merges `McpFilterConfig.fromFile('.dowel/mcp.json')`, `fromEnv` and `fromCli`.
2. `McpServer.initialize` reads state, connects once, builds plugin tools (`DowelRegistry.mcpTools`) plus substrate tools from `_safeDowelCommandNames`, applies the filter once and registers the survivors.
3. `McpServer._dispatch` sends a `dowel:` name to `_dispatchDowelCommand`, `tapir_evaluate` to `_dispatchEvaluate`, and any other tool to `callServiceExtension`.

## Decisions

| Decision | Why | Rejected alternatives | Status |
|----------|-----|-----------------------|--------|
| Session directory per project, keyed by a SHA-256 prefix of the canonical root of the nearest `pubspec.yaml` ancestor | One global `state.json` let another project's `start` take the slot; the log and FIFO collide for the same reason | A single global file | Active |
| `~/.dowel/state.json` still written as a pointer to the last start | The recovery recipe hand-writes it and external tools read it | Dropping it | Active |
| MCP tool collection is a separate opt-in call on the registry | CLI invocations pay nothing for descriptors they never consume | Collecting inside `registerProvider` | Active |

## Change guide

| To change | Touch | Also check |
|-----------|-------|------------|
| Add a builtin command | `lib/src/commands/<x>_command.dart`, `_builtinCommands` in `run_dowel.dart`, export in `lib/dowel.dart` | `test/commands/<x>_command_test.dart`, `doc/commands/`; `_safeDowelCommandNames` only if the model may call it |
| Change the signature DSL | `lib/src/console/command_signature.dart`, `dowel_command.dart` | `test/console/command_signature_test.dart`, `doc/reference/signature-dsl.md` |
| Add an `InstallOperation` | `install_operation.dart`, `InstallTransaction._stageOp` and `_serializeOp`, `DryRunRenderer.render`, `ConflictDetector._isHelperEdit` and `_targetAbsPath`, `ManifestInstaller.reverseOf` | `ManifestInstaller._opFromRecord` and `PluginUninstallCommand._opFromRecord` switch on strings, so the compiler will not flag a missing case; `doc/plugins/installer-dsl.md` |
| Add a DSL method over an existing operation | `plugin_installer.dart` | a `test/installer/plugin_installer_*_test.dart`, `doc/plugins/installer-dsl.md` |
| Add an `install.yaml` key | `install_manifest.dart`, `manifest_parser.dart`, a `ManifestInstaller._apply*` method | `doc/plugins/install-yaml.md`, `test/installer/manifest_parser_test.dart` |
| Add an editor | `lib/src/helpers/<x>_editor.dart`, export in `lib/dowel.dart`, a `_stageOp` arm and `_helperWrittenTargets` | `test/helpers/<x>_editor_test.dart` |
| Add a substrate MCP tool | `_safeDowelCommandNames`, `_mcpDescriptionFor`, `_commandInputSchema` in `mcp_server.dart` | `test/mcp/mcp_server_test.dart`, `doc/mcp/tool-reference.md` |
| Add an MCP filter layer | `mcp_filter_config.dart` (`fromX`, `merge`, `apply`), `mcp_serve_command.dart` | `test/mcp/mcp_filter_config_test.dart`, `doc/mcp/setup.md` |
| Change the state schema | `state_file.dart` (class doc), `StartCommand.bootingState` and `readyState` | every reader: `stop`, `reload`, `hot_restart`, `restart`, `status`, `_runWithConnected`, `mcp_server.dart` |
| Add a generated consumer file | a stub in `assets/stubs/`, its writer in `lib/src/commands/` | `install_command.dart`, `assets/stubs/dispatcher.dart.stub` |

## Traps

- `McpFilterConfig.fromFile` reads `.dowel/mcp.json` relative to the working directory, not the project root: `lib/src/commands/mcp_serve_command.dart`.
- `_classPattern` in `lib/src/commands/commands_index_writer.dart` matches every `class X extends *Command` in `lib/app/commands/`, including intermediate bases and commented-out code, and each match is registered in `_index.g.dart`.
- `toolsDeny` matches the MCP name (`dowel_hot_restart`), not the command name: `lib/src/mcp/mcp_filter_config.dart`.

Last reviewed: 2026-11-14 after the init-project prep.

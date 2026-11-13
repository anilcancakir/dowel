<p align="center">
  <img src="https://raw.githubusercontent.com/fluttersdk/magic/master/.github/magic-logo.svg" width="120" alt="Dowel Logo" />
</p>

<h1 align="center">Dowel</h1>

<p align="center">
  <strong>Composable CLI framework and stdio MCP server for Flutter and Dart.</strong><br/>
  Scaffolding, code generation, transactional plugin installs, hot reload orchestration, REPL, and AI agent tool surfaces in one binary.
</p>

<p align="center">
  <a href="https://pub.dev/packages/dowel"><img src="https://img.shields.io/pub/v/dowel.svg" alt="pub package"></a>
  <a href="https://github.com/anilcancakir/dowel/actions"><img src="https://img.shields.io/github/actions/workflow/status/anilcancakir/dowel/ci.yml?branch=master&label=CI" alt="CI"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://pub.dev/packages/dowel/score"><img src="https://img.shields.io/pub/points/dowel" alt="pub points"></a>
  <a href="https://github.com/anilcancakir/dowel/stargazers"><img src="https://img.shields.io/github/stars/anilcancakir/dowel?style=flat" alt="GitHub stars"></a>
</p>

<p align="center">
  <a href="https://anilcancakir.com/dowel">Documentation</a> ·
  <a href="https://pub.dev/packages/dowel">pub.dev</a> ·
  <a href="https://github.com/anilcancakir/dowel/issues">Issues</a>
</p>

---

## Why Dowel?

Dart's CLI surface is fragmented. Every package invents its own install ritual, its own scaffold script, its own hand-edited entry point. A team that adopts five tools ends up with five `bin/*.dart` wrappers, five README install sections, and five chances for a bad merge to silently break the build. AI agents that want to drive the running app reach for ad hoc shell scripts because there is no shared tool surface.

**Dowel fixes this.** One binary registers every command, one protocol describes every plugin install, and one stdio MCP server exposes the whole stack to AI agents.

```bash
# Before, the painful manual setup ritual
edit pubspec.yaml                          # add the plugin dependency
edit bin/<custom>.dart                     # wire the provider
edit lib/main.dart                         # register the config factory
edit android/app/src/AndroidManifest.xml   # add the permission
edit ios/Runner/Info.plist                 # add the entry
write .env stub                            # remember which keys
restart the app and hope nothing collided
```

```bash
# After, the Dowel way
dart pub add dowel
dart run dowel install
dart run dowel plugin:install <name>
```

If you know `php artisan`, you already know the verb shape. The implementation is pure Dart 3.4+, no Flutter runtime dependency in the framework core.

## Features

| | Feature | Description |
|:--|:--------|:------------|
| 🎼 | **Command Registry** | `DowelRegistry` collects commands from every registered `DowelServiceProvider`, collision-detected at boot |
| 🧰 | **22 Built-in Commands** | Lifecycle, scaffolding, plugin management, MCP, introspection, codegen, one binary |
| ✍️ | **Signature DSL** | `String get signature => 'cmd:name {arg} {--flag}'`, Dart 3 record-style parser, ArgParser fallback when needed |
| 🤖 | **MCP Server** | Stdio JSON-RPC server built on `dart_mcp`, exposes substrate and plugin tools to AI agents |
| 🌳 | **Magic-Free Path** | `install` writes a canonical wrapper for plain Flutter and Dart projects, no framework dependency |
| 🔌 | **Plugin Protocol** | `install.yaml` declarative manifest plus `PluginInstaller` fluent DSL escape hatch |
| 🔄 | **Idempotent Installs** | Lookahead-anchored regex injection, replace-by-name registry, re-running an install is a safe no-op |
| ↩️ | **Reversible Ops** | Every applied operation is recorded under `.dowel/installed/<plugin>.json`, `plugin:uninstall` walks it in reverse |
| 🪞 | **VM Service Hooks** | `tinker`, `reload`, `hot-restart` drive the running Flutter VM directly over `ext.*` extensions |
| 🎯 | **Context-Aware Generators** | `make:command` detects plugin vs consumer context, `make:plugin` upgrades to magic-mode automatically |
| 🧪 | **Testable Primitives** | `VirtualFs` plus `InMemoryFs`, `InstallContext.test`, `DowelContext.bare`, `BufferedOutput` capture |

## Quick Start

### 1. Install and scaffold

```bash
dart pub add dowel
dart run dowel install
```

`install` writes `bin/dispatcher.dart` (the consumer entry that calls `runDowel(...)`) plus barrels (`lib/app/_plugins.g.dart`, `lib/app/commands/_index.g.dart`), then auto-chains `make:fast-cli` so `bin/dowel` is ready immediately. Re-running is idempotent, pass `--force` to overwrite.

After scaffold, run any built-in command via the consumer wrapper:

```bash
dart run dowel list
dart run dowel doctor
dart run dowel start --device=chrome
```

### 2. Install a plugin

```bash
dart pub add awesome_plugin
dart run dowel plugin:install awesome_plugin
```

Plugins ship either an `install.yaml` manifest (declarative, walked by `ManifestInstaller`) or a procedural `DowelInstallCommand` subclass that drives `PluginInstaller` directly. Either way, the registry records every applied operation so a future `plugin:uninstall` can reverse them safely.

Plugin commands surface automatically. After installing `tapir`, `dart run dowel list` shows the new `tapir:*` entries under their own namespace section.

### 3. Wire the MCP server for your AI agent

```bash
./bin/dowel mcp:install
# or, on Windows / when bin/dowel is absent:
# dart run dowel mcp:install
```

`mcp:install` writes (or updates) the `mcpServers.dowel` entry in `.mcp.json`. After install, reconnect the MCP client once (for Claude Code: `/mcp reconnect dowel`). The server boots in stdio JSON-RPC mode and exposes 10 substrate tools (`dowel_start`, `dowel_stop`, `dowel_status`, `dowel_logs`, `dowel_restart`, `dowel_reload`, `dowel_hot_restart`, `dowel_doctor`, `dowel_list`, `dowel_tinker`) plus any plugin-contributed tools.

Read the full setup walkthrough at [MCP setup guide](https://anilcancakir.com/dowel/docs/mcp/setup).

## Commands

Dowel ships 22 built-in commands across 6 namespaces. Every command is a `final class X extends DowelCommand` with a `signature` string and a `handle()` method.

| Namespace | Count | Commands |
|:----------|:-----:|:---------|
| **Lifecycle** | 7 | `start`, `stop`, `status`, `logs`, `restart`, `reload`, `hot-restart` |
| **Scaffolding** | 4 | `make:plugin`, `make:command`, `make:fast-cli`, `install` |
| **Plugin Management** | 3 | `plugin:install`, `plugin:uninstall`, `plugins:refresh` |
| **MCP** | 3 | `mcp:serve`, `mcp:install`, `mcp:uninstall` |
| **Introspection** | 4 | `help`, `list`, `doctor`, `tinker` |
| **Codegen** | 1 | `commands:refresh` |

Highlights:

```bash
# Lifecycle
dart run dowel start --device=chrome   # spawn flutter run, record the session under ~/.dowel/sessions/<project>/
dart run dowel reload                  # send r (hot reload) via FIFO bridge to detached process
dart run dowel hot-restart             # send R (hot restart, drops Dart state)

# Scaffolding
dart run dowel make:plugin awesome     # 7-file plugin skeleton, auto-upgrades to magic-mode when applicable
dart run dowel make:command Greet      # context-aware: plugin vs consumer context, auto-registers in provider
dart run dowel make:fast-cli           # compile dowel to native binary at bin/dowel (~50ms startup vs ~3s)

# Introspection
dart run dowel tinker                  # connected REPL against the running VM
dart run dowel tinker --eval='1 + 1'   # one-shot evaluation flag for automation
dart run dowel doctor                  # preflight checks: flutter + dart on PATH, default port availability
```

Full command catalog and per-command flag reference at [commands catalog](https://anilcancakir.com/dowel/docs/commands/).

### Writing your own command

`make:command` scaffolds a `final class` extending `DowelCommand` and auto-registers it in the nearest service provider. The signature DSL parses arguments and flags from one string, the `handle()` method receives a typed `DowelContext`:

```dart
final class GreetCommand extends DowelCommand {
  @override
  String get signature => 'greet {name} {--shout}';

  @override
  String get description => 'Greet a person by name.';

  @override
  Future<int> handle(DowelContext context) async {
    final name = context.input.argument('name');
    final shout = context.input.option('shout') == 'true';
    final greeting = shout ? 'HELLO, ${name.toUpperCase()}!' : 'Hello, $name';
    context.output.success(greeting);
    return 0;
  }
}
```

For cases the signature DSL cannot express (positional rest, mutually exclusive flag groups), override `void configure(ArgParser parser)` and read from `context.input.results` directly. Signature DSL grammar at [signature DSL reference](https://anilcancakir.com/dowel/docs/reference/signature-dsl).

## Plugin Protocol

Dowel plugins declare their install footprint in `install.yaml`, a declarative manifest walked by `ManifestInstaller`. The manifest supports `publish` (files to copy), `magic.provider` plus `magic.configFactory` plus `magic.routes` (framework wiring), `native.android` (permissions, metaData, gradle plugins, gradle dependencies), `native.ios` and `native.macos` (plist entries, pod entries), `native.web` (head injections, meta tags), `env` (environment variable declarations with defaults), `prompts` (interactive install prompts), `placeholders` (token resolution from prompt answers), and `bootstrap_command` (post-install hint). Schema reference at [install.yaml schema](https://anilcancakir.com/dowel/docs/plugins/install-yaml).

A minimal `install.yaml` looks like this:

```yaml
publish:
  - from: stubs/config.dart
    to: lib/config/awesome.dart

magic:
  provider: package:awesome/awesome_provider.dart
  configFactory: package:awesome/config.dart

native:
  android:
    permissions:
      - android.permission.INTERNET
  ios:
    plistEntries:
      NSCameraUsageDescription: "We need the camera to scan codes."

env:
  AWESOME_API_KEY:
    default: ""
    comment: "API key for awesome.example.com"

bootstrap_command: "Run dart run dowel awesome:bootstrap after install."
```

For plugins that need runtime branching the YAML schema cannot express, subclass `DowelInstallCommand` and drive `PluginInstaller` directly. The DSL exposes file operations (`writeFile`, `publishConfig`, `mergeJson`), source-injection operations (`injectImport`, `injectBefore`, `injectAfter`, `injectProvider`, `injectConfigFactory`, `injectRoute`), native operations (`injectAndroidPermission`, `injectIosPlistEntry`, and friends), and environment operations (`injectEnvVar`). Every operation is deferred and batched, nothing writes until `commit(dryRun:, force:)` fires:

```dart
final class AwesomeInstallCommand extends DowelInstallCommand {
  @override
  String get signature => 'awesome:install';

  @override
  Future<int> handle(DowelContext context) async {
    final apiKey = await installer.ask('Enter the awesome API key:');
    installer
      ..injectImport('lib/main.dart', 'package:awesome/awesome.dart')
      ..injectConfigFactory('Awesome.configFactory')
      ..injectEnvVar('AWESOME_API_KEY', defaultValue: apiKey)
      ..injectAndroidPermission('android.permission.INTERNET');

    final result = await installer.commit(dryRun: false, force: false);
    return result is Success ? 0 : 1;
  }
}
```

Full DSL reference at [PluginInstaller DSL reference](https://anilcancakir.com/dowel/docs/plugins/installer-dsl).

Operations are idempotent (lookahead-anchored regex skips when the target code is already present), atomic (every write goes through `.tmp` plus atomic rename so concurrent readers never see partial state), and reversible (each applied operation is recorded under `.dowel/installed/<plugin>.json` with a content hash for tamper detection on uninstall).

## MCP Server

The same binary that runs CLI commands also serves Model Context Protocol tools over stdio JSON-RPC. No separate process, no extra package. The server is built on the official `dart_mcp` SDK and surfaces two tool layers.

**Substrate tools (10 always-on).** A curated subset of the dowel CLI surfaces as MCP tools so an AI agent can bootstrap the Flutter app without leaving the chat: `dowel_start`, `dowel_stop`, `dowel_status`, `dowel_logs`, `dowel_restart`, `dowel_reload`, `dowel_hot_restart`, `dowel_doctor`, `dowel_list`, `dowel_tinker`. Dispatch runs in-process via the registry; only `dowel_tinker` requires a running VM Service. Per-command `inputSchema` is byte-verified against the underlying command's `configure(ArgParser)` so the wire contract cannot drift from the CLI surface.

**Plugin tools.** Contributed by `DowelServiceProvider.mcpTools()` overrides. Dispatch routes through `ext.*` VM Service extensions. The official sibling plugins maintain their own MCP tool catalogs on dedicated reference pages:

| Plugin | MCP tool reference |
|:-------|:-------------------|
| `tapir` | [anilcancakir.com/tapir/docs/mcp/tool-reference](https://anilcancakir.com/tapir/docs/mcp/tool-reference) |
| `crumbs` | [anilcancakir.com/crumbs/docs/mcp/tool-reference](https://anilcancakir.com/crumbs/docs/mcp/tool-reference) |

A three-layer filter pipeline (`.dowel/mcp.json` file, `DOWEL_MCP_*` env vars, CLI flags on `mcp:serve`) lets operators allow or deny tools and packages with Cargo-style precedence, deny wins at every layer. Worked example:

```jsonc
// .dowel/mcp.json
{
  "packages": { "deny": ["crumbs"] }
}
```

```bash
# Env (process-scoped, overrides file)
export DOWEL_MCP_PACKAGES_DENY=crumbs

# CLI (session-scoped, overrides env)
dart run dowel mcp:serve --exclude-tool dowel_stop
```

Result: the Crumbs package is removed by the file, also denied by the env (union is idempotent), and `dowel_stop` is removed by the CLI flag for this session.

After `mcp:install` writes the client config entry, every MCP-capable agent can spawn the server on demand:

```jsonc
// .mcp.json (managed by mcp:install)
{
  "mcpServers": {
    "dowel": {
      "command": "./bin/dowel",
      "args": ["mcp:serve"],
      "cwd": "."
    }
  }
}
```

When `bin/dowel` is absent (or the host is Windows, where the POSIX shim never applies), `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead. Pass `--invocation=<executable>` to override the fallback entry point: `mcp:install` then writes `{"command": "dart", "args": ["run", "<executable>", "mcp:serve"]}`, which is the correct shape when the consumer's entry point is a plugin wrapper rather than the generic `:dispatcher` (for example, `dart run dowel mcp:install --invocation=tapir`). Precedence: if the host is POSIX and `bin/dowel` is present then `bin/dowel` wins, otherwise `--invocation` wins when supplied, otherwise the `:dispatcher` default applies.

When no session is recorded for the project at `initialize` time (no Flutter app running), the server stays online with the 10 substrate tools available and 0 plugin tools registered. On the next `tools/call` requiring VM Service, the server lazy-reconnects via a memoized in-flight future so MCP clients survive the natural dev cycle of starting and stopping the Flutter app without reconnecting.

Setup walkthrough at [MCP setup guide](https://anilcancakir.com/dowel/docs/mcp/setup). Full tool reference at [tool reference](https://anilcancakir.com/dowel/docs/mcp/tool-reference).

## Architecture

Dowel is subsystem-first under `lib/src/`, every directory owns a single concern:

```
lib/
├── dowel.dart                # Single barrel, re-exports the full public API
├── dowel.dart     # Convention sibling, re-exports the same surface
└── src/
    ├── console/                # DowelApplication, DowelRegistry, CommandSignature DSL, DowelContext
    ├── commands/               # 21 built-in commands, one final class per file
    ├── installer/              # PluginInstaller DSL, ManifestInstaller, InstallTransaction, sealed InstallOperation
    ├── mcp/                    # McpServer, McpToolDescriptor, McpFilterConfig (3-layer filter pipeline)
    ├── helpers/                # FileHelper, ConfigEditor, MainDartEditor, EnvEditor, PlistWriter, StringHelper
    ├── stubs/                  # StubLoader, asset bundle plus filesystem resolution
    ├── state/                  # StateFile, JSON persistence for start, stop, status, mcp:serve discovery
    ├── tinker/                 # Connected REPL primitives over ext.tinker.evaluate
    └── vm/                     # VmServiceClient, wraps package:vm_service, DDS-aware, no isolate-id cache
```

Flow at boot:

```
runDowel(args)
    ↓
DowelApplication.create(providers, builtins)
    ↓
DowelRegistry.registerAll(providers + builtins)   # collision-detected
    ↓
[CLI path] dispatch by signature       OR   [MCP path] collectMcpTools then serve stdio
    ↓
DowelCommand.handle(DowelContext)
```

Every public type is a `final class`. Sealed dispatch over Dart 3 exhaustiveness wherever an op set or result set is closed (`InstallOperation` has 28 sealed subclasses, `TransactionResult` has 4). New ops or result variants force every dispatcher to update, no silent drift.

## AI Agent Integration

Use Dowel with AI coding assistants like Claude Code, Cursor, or GitHub Copilot. The MCP server gives the agent direct tool access: start the Flutter app, drive widget interactions over Tapir, inspect HTTP traffic over Crumbs, evaluate Dart expressions over Tinker, all without spawning shells or pattern-matching log output.

A typical agent session looks like this:

```
[agent] dowel_doctor                              // verify toolchain
[agent] dowel_start { device: chrome }            // launch the app
[agent] <tapir tool>                      // capture Semantics tree, drive interaction
[agent] <crumbs tool>                 // inspect HTTP, logs, exceptions
[agent] dowel_tinker { eval: "User.find(1)" }     // poke the running VM
[agent] dowel_stop                                // tear down
```

See each plugin's MCP tool reference for the current tool catalog
([tapir](https://anilcancakir.com/tapir/docs/mcp/tool-reference),
[crumbs](https://anilcancakir.com/crumbs/docs/mcp/tool-reference)).

For agents that read structured project context at attach time, the canonical entry point is [`llms.txt`](llms.txt) at the repo root (also published at `https://anilcancakir.com/dowel/docs/llms.txt`). It enumerates the command surface, the plugin protocol, and the MCP tool catalog in agent-readable form.

Skill files and per-agent setup recipes: **[anilcancakir/skills](https://github.com/anilcancakir/skills)**.

## Documentation

Full docs with live examples at **[anilcancakir.com/dowel](https://anilcancakir.com/dowel)**.

| Topic | |
|:------|:-|
| [Getting Started](https://anilcancakir.com/dowel/docs/getting-started/) | Overview, requirements, first command |
| [Installation](https://anilcancakir.com/dowel/docs/getting-started/installation) | `dart pub add dowel` plus consumer scaffold |
| [Quickstart](https://anilcancakir.com/dowel/docs/getting-started/quickstart) | The 3-step path from empty repo to running MCP server |
| [Commands](https://anilcancakir.com/dowel/docs/commands/) | The 21 built-in commands, grouped by namespace |
| [Signature DSL](https://anilcancakir.com/dowel/docs/reference/signature-dsl) | Argument and flag declaration grammar |
| [Plugin Authoring](https://anilcancakir.com/dowel/docs/plugins/authoring) | The 5-step plugin authoring flow |
| [install.yaml Schema](https://anilcancakir.com/dowel/docs/plugins/install-yaml) | Every section, every key, every example |
| [PluginInstaller DSL](https://anilcancakir.com/dowel/docs/plugins/installer-dsl) | The procedural escape hatch reference |
| [MCP Overview](https://anilcancakir.com/dowel/docs/mcp/overview) | Substrate plus plugin tool layers, soft-fail lifecycle |
| [MCP Setup](https://anilcancakir.com/dowel/docs/mcp/setup) | Per-client install (Claude Code, Cursor, Continue) |
| [MCP Tool Reference](https://anilcancakir.com/dowel/docs/mcp/tool-reference) | Every tool, every input schema, every example call |

## Contributing

```bash
git clone https://github.com/anilcancakir/dowel.git
cd dowel && dart pub get
dart test && dart analyze
```

The baseline is roughly 1070 tests green on the touched-files scope. New behavior ships with the matching test (red, green, refactor). `dart format lib/ test/ bin/` must produce no diff and `dart analyze` must report zero issues across `lib/`, `test/`, and `bin/`.

Before opening a pull request, also run:

```bash
dart format lib/ test/ bin/         # zero diff
dart analyze                         # zero issues
dart pub publish --dry-run           # validate the publish archive
```

The publish archive must stay under 500 KB compressed. The `.pubignore` excludes `example/`, `example_magic/`, `build/`, `coverage/`, and editor scaffolding from the pub archive, extend it if you add new top-level directories that should not ship.

[Report a bug](https://github.com/anilcancakir/dowel/issues/new?template=bug_report.yml) · [Request a feature](https://github.com/anilcancakir/dowel/issues/new?template=feature_request.yml)

## License

MIT, see [LICENSE](LICENSE) for details.

---

<p align="center">
  <sub>Built with care by <a href="https://anilcancakir.com">Anılcan Çakır</a></sub><br/>
  <sub>If Dowel saves you time, <a href="https://github.com/anilcancakir/dowel">give it a star</a>, it helps others discover it.</sub>
</p>

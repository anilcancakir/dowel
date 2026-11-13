# MCP Server Setup

The dowel CLI ships with a built-in [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server that exposes your running Flutter app to AI coding assistants. The server speaks stdio JSON-RPC and surfaces tools contributed by every registered `DowelServiceProvider` (substrate commands plus Tapir, Crumbs, and any custom plugin).

- [Without dowel MCP](#without-dowel-mcp)
- [With dowel MCP](#with-dowel-mcp)
- [Installation](#installation)
- [Server Identity](#server-identity)
- [Add a Rule](#add-a-rule)
- [Automated Install](#automated-install)
- [Available Tools](#available-tools)

This page documents the per-client install matrix: the exact configuration snippet each MCP-compatible client needs to spawn `./bin/dowel mcp:serve` (or `dart run :dispatcher mcp:serve` as a fallback) against your project. The dowel MCP server is stdio-only in V1 (no remote HTTP endpoint); every client below launches the CLI locally with the project directory as the working directory.

<a name="without-dowel-mcp"></a>
## Without dowel MCP

LLM agents working against a running Flutter app are blind without dowel MCP:

- No access to the live VM Service: cannot read `Magic.find<X>().rxState` or any controller state.
- No way to drive the UI: gestures, snapshots, screenshots, modal waits all need the Tapir extension surface.
- No HTTP / log / exception inspection: Crumbs's runtime feed stays invisible.
- No connected REPL: every state inspection becomes a `print()` round-trip + hot-reload.

<a name="with-dowel-mcp"></a>
## With dowel MCP

The dowel MCP server bridges the agent to the running app over the VM Service:

- 10 substrate command tools (`dowel_start`, `dowel_stop`, `dowel_status`, `dowel_logs`, `dowel_restart`, `dowel_reload`, `dowel_hot_restart`, `dowel_doctor`, `dowel_list`, `dowel_tinker`).
- Plugin tools surface automatically once the consumer's `bin/dispatcher.dart` wrapper registers the provider; see each plugin's MCP tool reference for the current catalog ([tapir](https://anilcancakir.com/tapir/docs/mcp/tool-reference), [crumbs](https://anilcancakir.com/crumbs/docs/mcp/tool-reference)).
- Tool visibility filters via `.dowel/mcp.json` + env vars + CLI flags (Cargo-style replace for allow, union for deny).
- Zero release-build impact: every dowel integration gates on `kDebugMode` at the consumer's `main.dart`.

Add `use dowel` to your prompt to nudge the agent toward the MCP tool surface:

```
Show me the current MonitorController state. use dowel
```

<a name="installation"></a>
## Installation

### Prerequisites

The MCP server ships with `dowel`. Add the package + scaffold the consumer wrapper first so `./bin/dowel` and `bin/dispatcher.dart` exist:

```bash
dart pub add dowel
dart run dowel install
```

`install` writes `bin/dispatcher.dart` + `bin/dowel` + the codegen barrels (one-time per project; idempotent on re-run). After that, `mcp:install` writes the `.mcp.json` entry the clients below consume.

### Canonical entry shape

The canonical `.mcp.json` entry shape (written by `./bin/dowel mcp:install` or `dart run dowel mcp:install`):

```json
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

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

Every client below uses the canonical shape above, though the `command` + `args` payload adjusts based on platform and dowel availability. The `cwd` field must point at the project root (the directory that contains `pubspec.yaml`).

---

### Cursor

Go to: **Settings, Cursor Settings, MCP, Add new global MCP server**.

Paste into `~/.cursor/mcp.json`:

```json
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

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

For project-scoped use, write the same snippet to `.cursor/mcp.json` in the project root. The spawned process is equivalent to running `./bin/dowel mcp:serve` from that directory.

---

### Claude Code

Run this command from the project root to add the dowel MCP server:

```bash
claude mcp add dowel -- ./bin/dowel mcp:serve
```

For project-scoped configuration:

```bash
claude mcp add --scope project dowel -- ./bin/dowel mcp:serve
```

(When `bin/dowel` is absent or on Windows, use `dart run :dispatcher mcp:serve` instead.)

You can also write `.mcp.json` directly with the canonical entry shape from the [Installation](#installation) section above.

> **Note:** Claude Code does NOT auto-reconnect on `.mcp.json` edits. Run `/mcp reconnect dowel` inside Claude Code after every edit to load the new entry.

---

### Claude Desktop

On Windows and macOS, install the official [Claude Desktop application](https://claude.ai/download).

Open **File, Settings, Developer, MCP Servers, Edit Config** to open `claude_desktop_config.json`:

- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`

Add the dowel MCP server configuration. Replace the `cwd` value with the absolute path to your Flutter project root, since Claude Desktop has no project context:

```json
{
  "mcpServers": {
    "dowel": {
      "command": "./bin/dowel",
      "args": ["mcp:serve"],
      "cwd": "/absolute/path/to/your/flutter/project"
    }
  }
}
```

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

> **Important:** Fully quit Claude Desktop via **File, Exit** (closing the window just minimizes it). Restart it for the new entry to take effect.

---

### VS Code (GitHub Copilot)

Create or edit `.vscode/mcp.json` in your project:

```json
{
  "servers": {
    "dowel": {
      "type": "stdio",
      "command": "./bin/dowel",
      "args": ["mcp:serve"],
      "cwd": "."
    }
  }
}
```

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

For user-level configuration, add the same entry to your VS Code settings under `chat.mcp.servers`.

---

### Windsurf

Add to your Windsurf MCP configuration:

```json
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

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

Reload the Cascade panel after editing the config; Windsurf spawns `./bin/dowel mcp:serve` on next request.

---

### JetBrains IDEs (Junie / AI Assistant)

**For Junie:** Open Junie, click the three dots in the top right corner, then **Settings, MCP Settings**:

```json
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

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

**For AI Assistant:** Go to **Settings, Tools, AI Assistant, MCP** and add the same entry via the "as JSON" option.

---

### Cline / Roo-Code

Add to your Cline MCP server configuration (typically `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` on macOS, equivalent paths on other OSes):

```json
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

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

Roo-Code reads the same `mcpServers` shape; point its config file at the snippet above.

---

### OpenCode

Add to your OpenCode configuration file (`~/.config/opencode/opencode.json` or per-project `opencode.json`):

```json
{
  "mcp": {
    "dowel": {
      "type": "local",
      "command": ["./bin/dowel"],
      "args": ["mcp:serve"],
      "enabled": true
    }
  }
}
```

When `bin/dowel` is absent or on Windows, `mcp:install` writes `["dart", "run", ":dispatcher", "mcp:serve"]` instead.

The `local` transport spawns the process directly; OpenCode inherits the working directory from where it was launched.

---

### Gemini CLI

Add to `~/.gemini/settings.json`:

```json
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

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

Restart `gemini` after editing; the CLI re-spawns `./bin/dowel mcp:serve` on the next session.

---

### Antigravity

[Antigravity](https://antigravity.google/) is Google's AI-powered IDE built on VS Code.

1. Open the **Agent** side panel (`Cmd/Ctrl + L` or **View, Open View..., Agent**).
2. Click **Additional options (...)** in the upper right of the Agent panel.
3. Select **MCP Servers**.
4. Click **Manage MCP Servers**.
5. Click **View raw config** in the upper right of the Manage MCPs editor view.
6. Add this configuration:

```json
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

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

> **Tip:** Install the [Dart and Flutter extensions](https://docs.flutter.dev/tools/vs-code) for the best development experience.

---

### Firebase Studio

[Firebase Studio](https://firebase.studio/) is an agentic cloud-based development environment by Google.

1. In your Firebase Studio project, create `.idx/mcp.json` if it does not exist.
2. Add the dowel MCP configuration:

```json
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

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

3. Rebuild your workspace:
   - Open the Command Palette (`Shift + Ctrl + P`).
   - Enter **Firebase Studio: Rebuild Environment**.

---

### Other Clients

For any other MCP-compatible client that supports stdio transport, spawn the server with:

```bash
./bin/dowel mcp:serve
```

When `bin/dowel` is absent or on Windows, spawn with `dart run :dispatcher mcp:serve` instead.

The working directory must contain a `pubspec.yaml` that depends on `dowel` (directly or via a path / git dep). Clients that require a JSON entry shape accept the canonical form:

```json
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

When `bin/dowel` is absent or on Windows, `mcp:install` writes `{"command": "dart", "args": ["run", ":dispatcher", "mcp:serve"]}` instead.

Remote HTTP transport is NOT supported in V1; the dowel MCP server is stdio-only because it bridges to the local VM Service URI recorded in this project's session by `./bin/dowel start` (or `dart run :dispatcher start` when `bin/dowel` is absent).

---

<a name="server-identity"></a>
## Server Identity

The dowel MCP server advertises itself as `serverInfo: {"name": "dowel_mcp", "version": "<package version>"}` in the `initialize` response. The `name` field is fixed regardless of the installed plugin set. Clients such as Claude Code, Cursor, Windsurf, and others derive tool prefixes (like `mcp__dowel__dowel_start`) from the `.mcp.json` key (typically `dowel`), not from `serverInfo.name`. The MCP specification treats `serverInfo.name` as a display hint, not a stable identifier for tool prefix derivation.

The `version` field in `serverInfo` tracks the package version at release time, manually synced as part of the release cut process. See the MCP specification at https://modelcontextprotocol.io/specification/2025-03-26/basic/lifecycle for the full lifecycle semantics. This addresses issue #9 NIT 7, which called out the version drift problem.

---

<a name="add-a-rule"></a>
## Add a Rule

To make the agent reach for dowel MCP without an explicit `use dowel` prompt, add a rule to your AI client:

**Cursor:** Settings, Rules.

**Claude Code:** Add to `CLAUDE.md` in the project root.

**Windsurf:** Memories panel, add a workspace rule.

**JetBrains AI Assistant:** Settings, Tools, AI Assistant, Custom Instructions.

Example rule:

```
Always use dowel MCP when working with this Flutter project. Inspect running app state via dowel_tinker, drive the UI via tapir_* tools, and read HTTP / log / exception feeds via crumbs_*. Prefer dowel_status before assuming the app is running.
```

---

<a name="automated-install"></a>
## Automated Install

The dowel CLI ships a built-in command that writes the canonical `.mcp.json` entry for you:

```bash
dart run dowel mcp:install
```

The command is idempotent: pre-existing `mcpServers` keys are preserved, and running it twice replaces the `dowel` key in-place without creating duplicates. By default it writes to `.mcp.json` in the current working directory; override the path via `--path`:

```bash
dart run dowel mcp:install --path .vscode/mcp.json
```

To remove the entry later:

```bash
dart run dowel mcp:uninstall
```

Both commands work without a running Flutter app; they only edit the JSON file.

---

<a name="available-tools"></a>
## Available Tools

The dowel MCP server surfaces 10 substrate tools plus plugin-contributed tools from any registered sibling plugin (`tapir`, `crumbs`, or custom plugins). See [tool-reference.md](./tool-reference.md) for the per-tool input schema, output shape, and example invocations of the substrate tools, plus links to each plugin's MCP tool reference for the current plugin tool catalog.

Tool visibility is filtered in three layers (file `.dowel/mcp.json` lowest priority, env vars middle, CLI flags highest priority; deny always wins over allow). To temporarily hide a tool surface without uninstalling the server, edit `.dowel/mcp.json`:

```json
{
  "packages": {
    "allow": null,
    "deny": []
  },
  "tools": {
    "allow": null,
    "deny": []
  }
}
```

After editing `.dowel/mcp.json` or env vars, run `/mcp reconnect dowel` inside Claude Code (or the equivalent reconnect action in your client); the server does NOT auto-reload in V1.

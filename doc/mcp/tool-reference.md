# MCP Tool Reference

Catalog of every MCP tool surfaced by `dowel` directly. The MCP server exposes
**10 substrate tools** (always available) plus plugin-contributed tools when the matching
provider is registered in the consumer's `bin/dispatcher.dart`. Plugin tool catalogs live on
each plugin's own documentation site (see [Plugin Tools](#plugin-tools) below).

- [Tool Naming Convention](#tool-naming-convention)
- [Substrate Tools](#substrate-tools)
- [Plugin Tools](#plugin-tools)
- [Filter Configuration](#filter-configuration)
- [Related Documentation](#related-documentation)

- [Tool Naming Convention](#tool-naming-convention)
- [Substrate Tools](#substrate-tools)
  - [dowel_start](#dowel_start)
  - [dowel_stop](#dowel_stop)
  - [dowel_status](#dowel_status)
  - [dowel_logs](#dowel_logs)
  - [dowel_restart](#dowel_restart)
  - [dowel_reload](#dowel_reload)
  - [dowel_hot_restart](#dowel_hot_restart)
  - [dowel_doctor](#dowel_doctor)
  - [dowel_list](#dowel_list)
  - [dowel_tinker](#dowel_tinker)
- [Plugin Tools](#plugin-tools)
- [Filter Configuration](#filter-configuration)
- [Related Documentation](#related-documentation)

---

<a name="tool-naming-convention"></a>
## Tool Naming Convention

### Substrate tools

Substrate tools are built-in dowel commands exposed by `McpServer` directly. Their names
follow the pattern `dowel_<command>` where the dowel command name is transformed:

- `:` (namespace separator) becomes `_`
- `-` (word separator) becomes `_`

Examples: `start` maps to `dowel_start`; `hot-restart` maps to `dowel_hot_restart`.

### Plugin tools

Plugin tools are contributed via `DowelServiceProvider.mcpTools()`. Each plugin package
owns a prefix that matches the package name or domain:

| Plugin package | Tool prefix | Reference |
|---|---|---|
| `tapir` | `tapir_` | [anilcancakir.com/tapir/docs/mcp/tool-reference](https://anilcancakir.com/tapir/docs/mcp/tool-reference) |
| `crumbs` | `crumbs_` | [anilcancakir.com/crumbs/docs/mcp/tool-reference](https://anilcancakir.com/crumbs/docs/mcp/tool-reference) |

The same `:` and `-` transformation applies inside the suffix part.

### Exclusions from the allowlist

Interactive (`help`), codegen (`make:*`, `*:refresh`), installer (`plugin:*`,
`install`), and MCP meta (`mcp:*`) commands are intentionally excluded. They
either require a TTY, mutate source on disk (better served by the client's own file tools),
or recurse into the MCP server itself. `tinker` was previously excluded as interactive but
is now absorbed into the substrate as `dowel_tinker` (the `--eval` one-shot path drives
the MCP surface).

---

<a name="substrate-tools"></a>
## Substrate Tools

The 10 substrate tools are always present when the MCP server starts. They are served
in-process: the server builds a `MapInput` from the MCP arguments, runs the dowel command
via `BufferedOutput`, and returns the combined stdout + exit code as MCP text content.

### dowel_start

Maps to dowel command: `start`

Starts the Flutter app in debug mode and records the process PID and VM Service URI in
this project's session file. Once it exists the plugin tools (tapir, crumbs,
tinker) can connect to the running VM.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `device` | string | first available | Flutter device id. Common values: `chrome` (web), `macos` (desktop), `<adb-serial>` (Android), or any id from `flutter devices`. |
| `port` | string | `3100` | Web port for the chrome device (numeric string). Ignored for non-web devices. |
| `vm-service-port` | string | `8181` | Port the VM Service binds to on the host. Change when 8181 is already taken. |
| `dds` | boolean | `false` | Enable the Dart Development Service (DDS) proxy. Set `true` when a tool requires DDS-only features. |
| `profile-static` | boolean | `false` | Run a device (Android, iOS, desktop) with `flutter run --profile`: release-like performance, no hot reload. On `chrome` it only tags the session, because a web profile build has no VM Service. |

### dowel_stop

Maps to dowel command: `stop`

Sends `SIGTERM` to the process group of the recorded Flutter tool, so `frontend_server` and
the other children stop with it, and waits up to 5 seconds for the group. A member still
there is sent `SIGKILL` and waited on for up to 5 seconds more; then, on a web session, the
web port gets up to 5 seconds to come free. A CDP session's Chrome is stopped the same way,
with its CDP port. A pid that now belongs to a process started after the session was recorded
is left alone. The call returns once the app is gone (about 15 seconds at worst, 30 with
Chrome), so a `dowel_start` straight after it does not race the old app for its port. Then it deletes this project's session; an app that outlives `SIGKILL`
keeps its session and fails the call, so it can be retried. On an Android device it also runs
`adb -s <serial> shell am force-stop <applicationId>` (the id comes from
`android/app/build.gradle*`), because signalling the flutter tool leaves the app running.
After this call, plugin tools will fail until `dowel_start` is called again.

No parameters.

### dowel_status

Maps to dowel command: `status`

Reads this project's session and returns the current process state as JSON: PID, device,
VM Service URI, start timestamp, and whether the process is still alive.

No parameters.

### dowel_logs

Maps to dowel command: `logs`

Returns buffered stdout/stderr lines produced by the Flutter process since it started. Use
this to see compilation errors, framework warnings, and `print()` output from the app.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `follow` | boolean | `false` | When `true`, tail the live log stream until the client disconnects (`-f` on the CLI). When `false`, return the most recent buffered lines and exit immediately. |

### dowel_restart

Maps to dowel command: `restart`

Sends a full restart signal to the running Flutter process via the VM Service. Equivalent to
pressing `R` in the flutter run terminal. All widget state is destroyed; static state in Dart
globals persists.

No parameters.

### dowel_reload

Maps to dowel command: `reload`

Sends a hot reload signal to the running Flutter process via the VM Service. Equivalent to
pressing `r` in the flutter run terminal. Updates code in place; widget state is preserved.
Faster than `dowel_restart` but does not pick up changes to `initState` or constructor
bodies.

No parameters.

### dowel_hot_restart

Maps to dowel command: `hot-restart`

Alias for the hot-restart cycle: tears down the widget tree and rebuilds from `main()` while
keeping the Dart VM alive. Faster than a full process restart; slower than hot reload. Use
when hot reload cannot pick up the change (e.g. changes to `StatefulWidget.createState`,
`didChangeDependencies`, or provider boot logic).

No parameters.

### dowel_doctor

Maps to dowel command: `doctor`

Checks the dowel environment: Flutter SDK on `PATH`, `flutter devices` reachability,
state file presence, and VM Service connectivity. Returns a summary report with per-check
status (OK / WARNING / ERROR). Run this first when plugin tools fail unexpectedly.

No parameters.

### dowel_list

Maps to dowel command: `list`

Lists every registered dowel command with its signature and description. Output mirrors
`dart run dowel list`. Useful for discovering commands contributed by plugin providers
registered in the consumer's `bin/dispatcher.dart`.

No parameters.

### dowel_tinker

Maps to dowel command: `tinker`

Evaluate a Dart expression inside the running Flutter app via the VM Service evaluate RPC.
Takes required `eval` argument (Dart expression). Returns the formatted evaluation result
as text. Dispatch follows the same lazy-reconnect path as plugin VM-extension tools; the
expression runs in the foreground isolate's root library scope and is passed through the
`Tinker.casters` chain before return.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `eval` | string | (required) | Dart expression to evaluate in the running app's root library (e.g. `User.current.name`, `MonitorController.instance.refresh()`, `1+1`). Runs synchronously in the foreground isolate; the formatted result returns as text. |

---

<a name="plugin-tools"></a>
## Plugin Tools

Plugin tools are contributed by sibling packages via `DowelServiceProvider.mcpTools()`.
They surface in the MCP server only when the corresponding provider is registered in the
consumer's `bin/dispatcher.dart` and the MCP server is restarted (run `./bin/dowel mcp:serve` or
`dart run :dispatcher mcp:serve` on Windows or when `bin/dowel` is absent).

Each plugin tool dispatches over a `ext.<domain>.*` VM Service extension registered by the
plugin inside the running Flutter app.

---

### tapir

E2E interaction driver. Tools operate over `ext.tapir.*` VM Service extensions installed by
`tapir` inside the running app. Tool names use the `tapir_` prefix.

The plugin's MCP tool catalog evolves alongside the package; the canonical reference lives
at [anilcancakir.com/tapir/docs/mcp/tool-reference](https://anilcancakir.com/tapir/docs/mcp/tool-reference)
(per-tool input schema, required parameters, return shape, example invocations).

---

### crumbs

Runtime inspector. Tools read ring buffers populated by `ext.crumbs.*` VM Service
extensions installed by `crumbs` inside the running app. Tool names use the
`crumbs_` prefix.

The plugin's MCP tool catalog evolves alongside the package; the canonical reference lives
at [anilcancakir.com/crumbs/docs/mcp/tool-reference](https://anilcancakir.com/crumbs/docs/mcp/tool-reference)
(per-tool input schema, required parameters, return shape, example invocations).

---

### Tinker (absorbed into the substrate)

The connected REPL is no longer a plugin tool: it ships as the substrate's
`dowel_tinker` (see above). `magic_tinker` is still consumed by the host app for the
interactive REPL CLI (`dart run dowel tinker`), but its MCP surface has been removed
to avoid duplicating the substrate path. Use `dowel_tinker` from any MCP client for
live state inspection, controller calls, or facade events.

---

<a name="filter-configuration"></a>
## Filter Configuration

The MCP server applies a three-layer filter (file, then env vars, then CLI flags) to
control which plugin tools surface. Each layer uses Cargo-style replacement for allow lists
and union for deny lists.

### Precedence rules

- **Allow lists**: CLI replaces env, which replaces file. A non-null allow list at a higher
  layer REPLACES the lower layer entirely. Null means "no opinion at this layer."
- **Deny lists**: union of all three layers. A tool denied in any layer stays denied.
- **Deny wins over allow**: when a name appears in both the effective allow set and the
  effective deny set, the deny wins.

### Layer 1: `.dowel/mcp.json`

Place this file in the project root (next to `bin/dispatcher.dart`):

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

Field reference:

| Key | Type | Meaning |
|---|---|---|
| `packages.allow` | `null` or `string[]` | `null` = allow all packages; array = allow only named packages |
| `packages.deny` | `string[]` | Package names always excluded (wins over allow) |
| `tools.allow` | `null` or `string[]` | `null` = allow all tool names; array = allow only named tools |
| `tools.deny` | `string[]` | Tool names always excluded (wins over allow) |

Package names match `DowelServiceProvider.providerName`: `dowel` (substrate),
`tapir`, `crumbs`. Tool names match `McpToolDescriptor.name` exactly
(e.g. `dowel_tinker`, or any name listed on each plugin's tool-reference site).

### Layer 2: environment variables

| Variable | Effect |
|---|---|
| `DOWEL_MCP_PACKAGES_ALLOW` | CSV of package names to allow |
| `DOWEL_MCP_PACKAGES_DENY` | CSV of package names to deny |
| `DOWEL_MCP_TOOLS_ALLOW` | CSV of tool names to allow |
| `DOWEL_MCP_TOOLS_DENY` | CSV of tool names to deny |

### Layer 3: CLI flags

Pass flags directly to the MCP server invocation:

```bash
./bin/dowel mcp:serve \
  --include-package=tapir \
  --exclude-tool=dowel_stop
```

CLI flags replace the env + file allow lists and are unioned into the deny sets.

**Example: expose tapir tools only**
`{ "packages": { "allow": ["tapir"], "deny": [] }, "tools": { "allow": null, "deny": [] } }`

**Example: hide destructive substrate tools**
`{ "packages": { "allow": null, "deny": [] }, "tools": { "allow": null, "deny": ["dowel_stop"] } }`

---

<a name="related-documentation"></a>
## Related Documentation

- [MCP Overview](overview.md): architecture, transport, and server entry points
- [MCP Setup](setup.md): consumer registration, `.mcp.json`, and first-run checklist

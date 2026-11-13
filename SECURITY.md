# Security Policy

## Supported Versions

Only the latest published version receives fixes.

## Reporting a Vulnerability

Report it through GitHub's private vulnerability reporting:
**[Open a private vulnerability report](https://github.com/anilcancakir/dowel/security/advisories/new)**

The report stays confidential until a fix is ready. Include the affected version, the platform, and the steps to reproduce. For a file that was written outside the project, name the path and the `install.yaml` operation that wrote it.

## Scope

This policy covers the `dowel` package: the CLI and its builtin commands, the plugin installer (`install.yaml` manifests and the `PluginInstaller` operations), the stdio MCP server and its tools, and the session files under `~/.dowel/` and `.dowel/`. Issues in a third-party plugin, `dart_mcp`, `vm_service` and the Flutter SDK belong to their maintainers.

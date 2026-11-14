# plugin:install

Register a third-party dowel plugin into the consumer project. After adding a
package to `pubspec.yaml` and running `flutter pub get`, `plugin:install` wires
the plugin's `DowelServiceProvider` without requiring manual edits to
`bin/dispatcher.dart` or `lib/app/_plugins.g.dart`.

- [Basic Usage](#basic-usage)
- [Synopsis](#synopsis)
- [Two Routing Modes](#two-routing-modes)
- [Examples](#examples)
- [Idempotency](#idempotency)
- [Reversibility](#reversibility)
- [Related Documentation](#related-documentation)

---

<a name="basic-usage"></a>
## Basic Usage

```bash
dart run dowel plugin:install <name>
```

`<name>` is the plugin's pubspec package name (e.g. `magic_logger`). The
package must be listed in `pubspec.yaml` and resolved via `flutter pub get`
before this command runs.

Pre-flight checks: the package must appear in `pubspec.yaml`, and
`.dart_tool/package_config.json` must contain the package name. Any failure
exits with code `1` before any write is attempted. A plugin without an
`install.yaml` also needs the scaffold from `dart run dowel install`
(`lib/app/_plugins.g.dart`); without it the command exits with code `1` and
tells you to run `install` first.

The command also refuses to run, with exit code `1`, when
`lib/app/_plugins.g.dart` registers providers but `.dowel/plugins.json`, the
registry the barrel is generated from, is missing. Installing then would
regenerate the barrel with a single plugin and drop the rest:

```text
lib/app/_plugins.g.dart registers providers from <imports>, but .dowel/plugins.json, the registry it is generated from, is missing. Installing now would regenerate the barrel without them. Restore .dowel/plugins.json from version control (commit it; only .dowel/cli-bundle/, .dowel/build.stamp and .dowel/.dowel.lock/ are cache), then retry.
```

Commit `.dowel/plugins.json` and `.dowel/installed/`; only the AOT cache under
`.dowel/` is gitignored.

---

<a name="synopsis"></a>
## Synopsis

Full signature as declared in
`lib/src/commands/plugin_install_command.dart`:

```
plugin:install
  {name                  : Plugin pubspec package name (e.g. magic_logger)}
  {--bootstrap-command=  : Plugin install sub-command to chain after registration}
  {--use-yaml-only       : Fail if install.yaml not found instead of registering the plugin directly}
  {--force               : Bypass conflict detection (inherited from DowelInstallCommand)}
  {--dry-run             : Print staged ops without writing (inherited)}
  {--non-interactive     : Skip prompts, use defaults (inherited)}
  {--no-bootstrap        : Skip post-install bootstrap hint message (inherited)}
```

The four inherited flags come from `DowelInstallCommand.baseFlags` and are
available on every install command, not only `plugin:install`.

| Flag | Effect |
|:---|:---|
| `--bootstrap-command=cmd` | Overrides the post-registration bootstrap hint (e.g. `logger:install`). |
| `--use-yaml-only` | Error out when no `install.yaml` found; no direct registration (Mode 2). |
| `--force` | Bypass conflict detection; overwrite user-modified files. |
| `--dry-run` | Print every staged op without touching disk. |
| `--non-interactive` | Skip interactive prompts; use defaults. Required in non-TTY environments. |
| `--no-bootstrap` | Suppress the post-install bootstrap hint message. |

---

<a name="two-routing-modes"></a>
## Two Routing Modes

The core of `handle` dispatches through two code paths. Mode 1 wins when an
`install.yaml` manifest is present; Mode 2 runs otherwise, and needs the
scaffold barrel from `dart run dowel install`.

### Mode 1: install.yaml Manifest Flow

**Condition**: `resolveInstallYaml(name)` returns a non-null path. The resolver
checks `<plugin_root>/install.yaml` first, then `<plugin_root>/assets/install.yaml`
(`resolveInstallYaml` in `lib/src/commands/plugin_install_command.dart`).

`ManifestParser.parseFile` parses the YAML into an `InstallManifest`.
`ManifestInstaller` stages `InstallOperation` objects on an `InstallTransaction`.
`InstallTransaction.commit` writes every file to a `.tmp` path first; on full
success, all `.tmp` files are renamed atomically. The result is one of four
classes: `InstallSuccess`, `InstallDryRun`, `InstallConflict` (exit code `2`) and
`InstallError` (exit code `1`). A conflict lists each file with its reason
(`modified-since-last-known-stub`, `unmanaged-file` or
`unsupported-install-record`); `--force` bypasses the check, which also switches
off every other conflict check, so read `git diff` afterwards. A `.tmp` write
failure deletes all staged temps and returns `InstallError(rolledBack: true)`,
unless an editor-backed operation (a dependency addition, an injection) already
changed a file: those write directly while staging and sit outside the `.tmp`
rollback, so the result then says `rolledBack: false` and a partial install
record (`"partial": true`) lists the edits that landed, for `plugin:uninstall`
to reverse what it can. On `InstallSuccess`, the plugin entry is written to
`.dowel/plugins.json` and `PluginsRefreshCommand` regenerates
`lib/app/_plugins.g.dart` in-process.

Preferred authoring path: declarative, conflict-checked, dry-run-capable, and
partially reversible via `plugin:uninstall` (see Reversibility).

### Mode 2: Direct Registration

**Condition**: No `install.yaml` found AND `lib/app/_plugins.g.dart` exists at
the project root. Without that barrel the command exits with code `1` and asks
you to run `dart run dowel install` first.

`_registerDowelProvider` runs directly: writes a `PluginEntry` to
`.dowel/plugins.json` and regenerates `_plugins.g.dart`. No wrapper edit
occurs. Covers plugins without a manifest. Naming convention: `my_plugin` maps
to `package:my_plugin/cli.dart` and class `MyPluginDowelProvider`. Pass
`--use-yaml-only` to error out instead of reaching this path.

---

<a name="examples"></a>
## Examples

### 1. Manifest-based plugin install (Mode 1)

```bash
flutter pub add magic_logger
dart run dowel plugin:install magic_logger
```

Output:
```
Success: applied 4 ops; record at .dowel/installed/magic_logger.json
Bootstrap with: dowel logger:install
```

### 2. Canonical scaffold, no install.yaml (Mode 2)

```bash
flutter pub add awesome_plugin
dart run dowel plugin:install awesome_plugin
```

Output:
```
Registered "awesome_plugin" via the dowel scaffold (no install.yaml needed).
```

### 3. Dry-run preview

```bash
dart run dowel plugin:install magic_logger --dry-run
```

Output:
```
DryRun: previewed 4 ops; no changes written
  WriteFile           lib/config/logger.dart
  InjectImport        lib/main.dart
  InjectAfterPattern  lib/app/providers/app_service_provider.dart
  AddPubspecAsset     assets/logging/
```

---

<a name="idempotency"></a>
## Idempotency

Re-running `plugin:install` for the same plugin is safe in both modes.
`PluginsRegistryFile.addPlugin` replaces by name so `.dowel/plugins.json`
always contains exactly one entry per plugin. `ConfigEditor.addImportToFile`
and `insertCodeAfterPattern` skip injection when the target content is already
present.

All `InstallTransaction` file writes use `.tmp` + atomic rename: concurrent
readers never observe partial state. A mid-commit `.tmp` write failure deletes
all staged temps and returns `InstallError(rolledBack: true)` before any rename
occurs, except after an editor-backed edit (see Mode 1).

A dependency the project already declares keeps its constraint: the manifest's
`pubspec` entries are added only when the pubspec does not list them.

---

<a name="reversibility"></a>
## Reversibility

`plugin:uninstall <name>` is the complement to `plugin:install`. A Mode 1
manifest commit writes `.dowel/installed/<name>.json`, through a temp file and
a rename:

| Key | Content |
|:---|:---|
| `version` | The record format, `1`. A record without it, or with absolute `stubHashes` keys, is not read. |
| `stubHashes` | The content hash of every file the install wrote, under project-relative, forward-slash keys, so a moved or re-cloned project still matches. |
| `ops` | Every operation with its typed payload. A dependency addition carries `preExisting`, true when the project declared that dependency before the install. |
| `partial` | Present and `true` only for the record of an install that failed after its editor-backed edits landed. |

Reversibility is partial: `plugin:uninstall` reverses the files an install
created (`WriteFile`, `PublishFile`, `CopyFile`, hash-checked) and the
dependency additions the project did not declare before (a `preExisting` one
stays in `pubspec.yaml`, and the command says which). Every other operation,
each `Inject*` among them, is logged as skipped: remove those edits by hand.
`plugin:uninstall` then removes the plugin from `.dowel/plugins.json` and
regenerates `lib/app/_plugins.g.dart`. Mode 2 installs write no record, so
`plugin:uninstall` cannot reverse them. `plugin:uninstall --dry-run` previews
only the `WriteFile` and `CopyFile` deletions, so it lists fewer reversals than
the real run performs (that also covers `PublishFile` files and dependencies).

A record written by an older dowel is refused by both commands: `plugin:install`
reports a conflict on the record (`unsupported-install-record`) and
`plugin:uninstall` exits `1` with `The install record <path> has no "version" (an
older dowel wrote it). Re-run the install with --force to rewrite it.` Run
`plugin:install <name> --force` once; it rewrites the record.

---

<a name="related-documentation"></a>
## Related Documentation

- [plugin:uninstall](index.md): removes a plugin registered via
  `plugin:install`, using the `.dowel/installed/<name>.json` record.
- [plugins:refresh](index.md): regenerates `lib/app/_plugins.g.dart`
  from `.dowel/plugins.json` when the codegen barrel drifts out of sync.
- [install.yaml schema](../plugins/install-yaml.md): full reference for the
  declarative manifest format consumed by Mode 1.

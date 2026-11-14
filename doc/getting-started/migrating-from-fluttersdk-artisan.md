# Migrating from fluttersdk_artisan

How to move an app that runs `fluttersdk_artisan` onto `dowel`, what `dowel install` and `dowel doctor` detect for you, and the one-time changes an app already on an earlier dowel meets.

- [Quick Reference](#quick-reference)
- [Migration Steps](#migration-steps)
- [What dowel Detects](#what-dowel-detects)
- [An App Already on an Earlier dowel](#earlier-dowel)
- [Gotchas](#gotchas)
- [Related Documentation](#related-documentation)

<a name="quick-reference"></a>
## Quick Reference

Nothing is migrated automatically. The package, the repository, the barrel, the classes, the executable and the state directories all changed name:

| Was | Is |
|:---|:---|
| `fluttersdk_artisan`, `package:fluttersdk_artisan/artisan.dart` | `dowel`, `package:dowel/dowel.dart` |
| `Artisan*` classes, `runArtisan` | `Dowel*` classes, `runDowel` |
| `.artisan/`, `~/.artisan/` | `.dowel/`, `~/.dowel/` |
| `bin/fsa` | `bin/dowel` |
| `ARTISAN_*` environment variables, `FSA_LOCK_TIMEOUT` | `DOWEL_*`, `DOWEL_LOCK_TIMEOUT` |
| `artisan_*` MCP tools, the `fluttersdk` entry in `.mcp.json` | `dowel_*` tools, the `dowel` entry |
| `<name>_artisan_provider.dart` | `<name>_dowel_provider.dart` |
| `fluttersdk_dusk`, `fluttersdk_telescope` | `tapir`, `crumbs` |

<a name="migration-steps"></a>
## Migration Steps

Run them in this order. `dart run dowel install` stops and prints the same list when it finds a generated file from the old package.

1. **Swap the packages.** Replace the old package, and each plugin with its renamed package (any other plugin needs a release built on dowel):

   ```bash
   dart pub remove fluttersdk_artisan
   dart pub add dowel
   ```

2. **Move the state directories.** Move `.artisan/` to `.dowel/` and `~/.artisan/` to `~/.dowel/`. Then delete `.dowel/plugins.json`, which names `fluttersdk_*` packages and `*ArtisanProvider` classes, and every `fluttersdk_*` record under `.dowel/installed/`. Keep the other install records.
3. **Delete the generated files.** Remove `bin/dispatcher.dart`, `bin/fsa`, a hand-injected `bin/artisan.dart`, `lib/app/_plugins.g.dart` and `lib/app/commands/_index.g.dart`: they import the old package and no longer compile. In your own commands and providers, import `package:dowel/dowel.dart` instead of `package:fluttersdk_artisan/artisan.dart` and rename each `Artisan*` class to `Dowel*`.
4. **Scaffold again, then register.**

   ```bash
   dart run dowel install
   dart run dowel commands:refresh
   dart run dowel plugin:install <name>
   ```

   `install` writes the dispatcher, the two barrels and `bin/dowel`, but only recreates an empty command index, so `commands:refresh` registers the commands under `lib/app/commands/` again. Run `plugin:install` once per plugin: a plugin's bootstrap command needs the new dispatcher. See [Gotchas](#gotchas) for the conflicts a reinstall can report.
5. **Replace the MCP entry.** Delete the `fluttersdk` entry from `.mcp.json`, then write the new one:

   ```bash
   ./bin/dowel mcp:install
   ```

   `mcp:install` adds `dowel` next to an existing `fluttersdk` entry and does not replace it, so the old one has to go first. Reconnect your MCP client afterwards.

<a name="what-dowel-detects"></a>
## What dowel Detects

`dowel install` and `dowel doctor` both look for what the old package left behind, so a half-finished migration is reported instead of failing inside a compiler error.

**`install`** stops, with exit code `1`, when `bin/dispatcher.dart`, `lib/app/_plugins.g.dart` or `lib/app/commands/_index.g.dart` still imports `package:fluttersdk_artisan/`, or names a class the old package exported or `runArtisan`. Each of them would otherwise be skipped as an existing file, and the build that follows would fail on its imports. It prints every leftover it found, then the steps:

```text
This project still has files from fluttersdk_artisan, which dowel replaced in 0.0.21:
  bin/dispatcher.dart
  bin/fsa
  .artisan/
  lib/app/commands/greet_command.dart
  .dowel/plugins.json
To migrate:
  1. dart pub remove fluttersdk_artisan && dart pub add dowel, and swap each plugin for its renamed package (fluttersdk_dusk is tapir, fluttersdk_telescope is crumbs).
  2. Move .artisan/ to .dowel/ and ~/.artisan/ to ~/.dowel/, then delete .dowel/plugins.json and the fluttersdk_* records under .dowel/installed/.
  3. Delete bin/dispatcher.dart, bin/fsa, bin/artisan.dart, lib/app/_plugins.g.dart and lib/app/commands/_index.g.dart; in your own commands import package:dowel/dowel.dart instead of package:fluttersdk_artisan/artisan.dart and rename Artisan* classes to Dowel*.
  4. dart run dowel install, then dart run dowel commands:refresh, then dart run dowel plugin:install <name> for each plugin.
  5. Delete the "fluttersdk" entry from .mcp.json, then run: dart run dowel mcp:install.
```

`install --force` skips the stop and overwrites the stale files, as it does for any existing file.

**`doctor`** prints the same list as a warning that never changes its exit code. It covers more than `install` does:

| It reports | When |
|:---|:---|
| `bin/dispatcher.dart`, `lib/app/_plugins.g.dart`, `lib/app/commands/_index.g.dart` | The file imports `package:fluttersdk_artisan/` or names a class the old package exported (`ArtisanCommand`, `ArtisanContext`, `ArtisanServiceProvider` and the rest dowel renamed) or `runArtisan`. |
| `bin/fsa`, `bin/artisan.dart` | The file exists. |
| `.artisan/` | The directory exists. |
| A file under `lib/app/commands/` | It still imports the old package or names one of those classes. A class of your own that only starts with `Artisan`, such as `ArtisanBreadCommand`, does not count. |
| `.dowel/plugins.json` | It names a `fluttersdk` package or an `ArtisanProvider` class. |
| `.dowel/installed/fluttersdk_*.json` | The record belongs to a package that no longer exists. |

It also warns about a `fluttersdk` entry in `.mcp.json`, in any shape, and says to delete it and run `mcp:install`:

```text
WARN: Old MCP entry detected. Your .mcp.json still has the "fluttersdk" server that fluttersdk_artisan wrote, and that package no longer exists. Delete the "fluttersdk" entry from .mcp.json, then run: ./bin/dowel mcp:install (or: dart run dowel mcp:install).
```

An entry that starts `fluttersdk_artisan:mcp` gets its own warning, under whatever key it sits:

```text
WARN: Outdated MCP entry detected. The "fluttersdk" server in .mcp.json starts fluttersdk_artisan:mcp, the MCP server of a package that no longer exists, and it never loads your plugins. Delete the "fluttersdk" entry from .mcp.json, then run: ./bin/dowel mcp:install (or: dart run dowel mcp:install).
```

`doctor` runs from dowel itself, like `install`, so it reaches these checks even while the old `bin/dispatcher.dart` is still there; it lists what remains to delete.

<a name="earlier-dowel"></a>
## An App Already on an Earlier dowel

An app that has already moved to dowel meets a few one-time changes when it updates:

| Change | What to do |
|:---|:---|
| **An old install record is refused.** A record under `.dowel/installed/` that has no `"version"`, or that stores absolute `stubHashes` keys, is not read. | `plugin:install <name>` reports a conflict on the record (`unsupported-install-record`) and `plugin:uninstall` refuses it with `The install record <path> has no "version" (an older dowel wrote it). Re-run the install with --force to rewrite it.` Run `plugin:install <name> --force` once per plugin; see [Gotchas](#gotchas). |
| **`.dowel/plugins.json` is tracked.** Earlier versions gitignored the whole `.dowel/` directory, which hid the registry the generated barrel comes from. | Re-run `dart run dowel make:fast-cli` (or `install`): it replaces a bare `.dowel/` line in `.gitignore` with `.dowel/cli-bundle*`, `.dowel/build.stamp*` and `.dowel/.dowel.lock/`. Then commit `.dowel/plugins.json`, `.dowel/installed/` and `.dowel/mcp.json`. |
| **`plugin:install` refuses a missing registry.** When `lib/app/_plugins.g.dart` registers providers but `.dowel/plugins.json` is missing, an install would regenerate the barrel with one plugin and drop the rest. | Restore the file from version control, or delete the barrel, run `dart run dowel install` to write an empty one and install each plugin again. The error says so: `... is missing. Installing now would regenerate the barrel without them. Restore .dowel/plugins.json from version control (commit it; only .dowel/cli-bundle*, .dowel/build.stamp* and .dowel/.dowel.lock/ are cache), then retry. Or delete lib/app/_plugins.g.dart, run `dart run dowel install` to write an empty one, and run plugin:install again for each plugin.` |
| **The `dowel` constraint stays as written.** `install` adds `dowel: ^<running version>` only when the pubspec has no `dowel` entry; it no longer writes `any`. | An unconstrained `any` entry an earlier install wrote stays too. Replace it with a caret constraint by hand. |
| **A dependency you declared survives `plugin:uninstall`.** The install record marks each dependency the project already had, and uninstall keeps it. | Nothing: records written before this change carry no mark, which is one more reason to reinstall once with `--force`. |
| **The Dart SDK floor moved.** dowel needs Dart 3.13 or newer. | Update the Dart SDK before `dart pub get`. |
| **`package:dowel/dowel.dart` exports a fixed list of symbols.** Most builtin command classes (`DoctorCommand`, `ListCommand`, `PluginInstallCommand` and the rest), `McpServer` and the internals are no longer exported, and `package:args` is re-exported only for `ArgParser`, `ArgParserException` and `ArgResults`. | Import `package:args/args.dart` for anything else. A plugin that hid `DoctorCommand` no longer needs the `hide`. |
| **The install results are renamed.** `Success`, `Conflict`, `DryRun` and `Error` are `InstallSuccess`, `InstallConflict`, `InstallDryRun` and `InstallError`. | Rename them in every `switch` over a `TransactionResult`. The old `Error` hid `dart:core`'s `Error`; it no longer does. |
| **Exported classes are `final`, and the seams are interfaces.** `DowelInput`, `PromptDriver`, `StubDriver` and `VirtualFs` are `interface` classes. | A test fake that extended `InMemoryFs` or `DowelRegistry` implements `VirtualFs` or builds the registry instead. |
| **`install.yaml` rejects an unknown top-level key.** | Fix the manifest: the error names the key, the manifest path and the running dowel version. |

<a name="gotchas"></a>
## Gotchas

| Mistake | Fix |
|:---|:---|
| Running `dart run dowel install` before `dart pub add dowel` | `dart run dowel` needs the dependency. Step 1 comes first. |
| Running `./bin/dowel <command>` right after `commands:refresh` and meeting `Unknown command` | `commands:refresh` does not rebuild the compiled `bin/dowel`, which still holds the empty index `install` built. Delete `.dowel/build.stamp` and the next `./bin/dowel` call rebuilds, or use `dart run :dispatcher <command>`, which compiles fresh. |
| Re-adding `.mcp.json` with `mcp:install` while the `fluttersdk` entry is still there | Both servers then run side by side. Delete the old entry first. |
| Reinstalling a plugin and meeting `unmanaged-file` or `unsupported-install-record` | A file a renamed plugin published earlier has no record, and a record kept from before it was versioned is refused. Commit or stash your work, run `plugin:install <name> --force`, then read `git diff`: `--force` switches off every conflict check, so it overwrites a file you edited. `--dry-run` skips the conflict check and cannot preview this. |
| Ignoring the whole `.dowel/` directory | A fresh clone then has no `plugins.json`, and the next `plugin:install` refuses to run. Ignore only the cache entries. |
| Hand-editing the generated barrels | They are overwritten. Run `commands:refresh` and `plugins:refresh`. |

<a name="related-documentation"></a>
## Related Documentation

- [Installation](installation.md): requirements and the scaffold `install` writes.
- [install](../commands/install.md): what the scaffold writes, how it picks the `dowel` constraint and when it stops.
- [plugin:install](../commands/plugin-install.md): the conflict check, the install record and its reversal.
- [MCP Setup](../mcp/setup.md): wire the server into an AI client after the `.mcp.json` entry changes.

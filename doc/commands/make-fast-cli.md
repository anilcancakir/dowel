# make:fast-cli

Scaffold a POSIX shell wrapper (`bin/dowel`) and AOT-compiled dowel binary for about 100 ms startup, avoiding the 3-second `dart run` overhead with build hooks.

- [Basic Usage](#basic-usage)
- [Synopsis](#synopsis)
- [What It Does](#what-it-does)
- [Output](#output)
- [Re-running](#re-running)
- [Staleness Detection](#staleness-detection)
- [Performance](#performance)
- [Caveats](#caveats)
- [Related Documentation](#related-documentation)

---

<a name="basic-usage"></a>
## Basic Usage

```bash
dart run dowel make:fast-cli
```

Writes `bin/dowel` (POSIX shell wrapper, executable), `.dowel/cli-bundle/` (compiled binary + runtime libraries) and `.dowel/build.stamp` (staleness marker), and patches `.gitignore` to ignore that cache. Caches the build result so subsequent invocations are cached (real time under 100ms on hit).

---

<a name="synopsis"></a>
## Synopsis

```
make:fast-cli {--force : Overwrite bin/dowel even when it already exists}
```

| Option | Description |
|:---|:---|
| `--force` | Rewrite `bin/dowel` and recompile the binary, even if a cached version exists. |

---

<a name="what-it-does"></a>
## What It Does

1. **Validates the project structure.** Checks for `pubspec.yaml` and `bin/dispatcher.dart`; errors with actionable guidance if either is missing.

2. **Scaffolds the wrapper script.** Writes a POSIX `sh` script at `bin/dowel` that resolves symlinks via a portable `follow_links()` subshell and derives the project root at runtime.

3. **Computes a staleness key.** Captures the SHA256 hash of `pubspec.lock` and the Dart SDK version string, storing both in `.dowel/build.stamp` for later comparison.

4. **Compiles the binary.** Runs `dart build cli -t bin/dispatcher.dart -o .dowel/cli-bundle`, producing an AOT-native binary at `.dowel/cli-bundle/bundle/bin/dispatcher`.

5. **Patches `.gitignore`.** Appends the cache entries `.dowel/cli-bundle/`, `.dowel/build.stamp` and `.dowel/.dowel.lock/` when they are missing, so the compiled cache is never tracked. The rest of `.dowel/` is source of truth and stays trackable: `plugins.json` is the registry `lib/app/_plugins.g.dart` is generated from, `installed/` holds the install records and `mcp.json` is the tool filter. A bare `.dowel/` line, which earlier versions wrote, is replaced by the three entries, because it also ignored `plugins.json`. Idempotent.

---

<a name="output"></a>
## Output

- **`bin/dowel`** (executable, ~50 LoC): shell wrapper that checks staleness, auto-recompiles if needed, then execs into the binary.
- **`.dowel/cli-bundle/bundle/bin/dispatcher`**: AOT-compiled native executable.
- **`.dowel/cli-bundle/bundle/lib/*.dylib`** (on macOS; `.so` on Linux): runtime libraries bundled with the binary.
- **`.dowel/build.stamp`**: one-line file with `<pubspec_lock_sha256>:<dart_sdk_version>`. Lets the wrapper detect when to rebuild.

---

<a name="re-running"></a>
## Re-running

Run `make:fast-cli` again without `--force`: the wrapper detects `bin/dowel` already exists and skips the override.

Run with `--force`: rewrites the wrapper and recompiles.

The wrapper script itself is the source of truth for staleness detection. When the user runs `./bin/dowel <cmd>` and the Dart SDK updates or `pubspec.lock` changes, the wrapper notices (inside the lock-acquire section) and transparently rebuilds. No manual re-run needed.

---

<a name="staleness-detection"></a>
## Staleness Detection

The wrapper's `needs_build()` function triggers a rebuild when any of these conditions hold:

1. **Binary missing.** The compiled executable at `.dowel/cli-bundle/bundle/bin/dispatcher` does not exist.

2. **Stamp file missing or empty.** The `.dowel/build.stamp` file is absent or has zero size.

3. **Stamp file content mismatches.** The stored compile key (format: `<sha256-of-pubspec.lock>:<dart-sdk-version>`) differs from the current key, meaning either the lock or the SDK changed.

4. **`pubspec.yaml` modified since last build.** The mtime of `pubspec.yaml` is newer than the stamp file's mtime, detected via the `-nt` (newer than) operator.

5. **`lib/app/_plugins.g.dart` modified since last build.** The mtime of `lib/app/_plugins.g.dart` is newer than the stamp file's mtime. It invalidates the cache when `plugin:install` or `plugins:refresh` regenerates the file.

Any match triggers a recompile inside the lock-acquire section. The re-check inside the lock prevents redundant builds when multiple invocations race.

### The build lock

`.dowel/.dowel.lock/` is a directory created with an atomic `mkdir` and holds the owner's pid. It is held only while building: the wrapper removes it and clears its trap before `exec`ing the binary, because `exec` replaces the shell and a trap would never run, which used to leave a long-lived `mcp:serve` holding the lock for its whole life. A dead owner's lock is reclaimed through a `kill -0` probe; a live owner is waited on for at most `DOWEL_LOCK_TIMEOUT` seconds (default 600), after which the call fails and names the pid. A build compiles into `.dowel/cli-bundle.build.<pid>` and is swapped in by rename, so a binary another process is running is never overwritten; leftovers from a killed build are removed by the next build.

---

<a name="performance"></a>
## Performance

### Cache hit (wrapper runs existing binary)

```bash
time ./bin/dowel status
# real 0m0.045s
# user 0m0.020s
# sys  0m0.015s
```

about 100 ms round-trip on a modern machine (no `dart run`, no "Running build hooks..." overhead).

### Cache miss (first run or staleness detected)

```bash
time dart run dowel make:fast-cli
# Building dowel CLI (one-time, ~5s)...
# real 0m8.234s
```

~8 seconds (depends on machine and dependency size). The wrapper prints "Building dowel CLI..." so users know a compile is in progress and not to interrupt.

### Comparison with `dart run`

```bash
time dart run dowel status
# real 0m3.100s
# (includes "Running build hooks..." unless all hooks are cached)

time ./bin/dowel status
# real 0m0.045s
# (cached; 68x faster)
```

---

<a name="caveats"></a>
## Caveats

**POSIX only (macOS and Linux).** Windows users use `dart run dowel <cmd>`; there is no `.cmd` variant.

**No cross-compilation.** The compiled binary targets the local machine architecture and OS. Distributing the binary to a different architecture or OS requires re-running `make:fast-cli` on that target.

---

<a name="related-documentation"></a>
## Related Documentation

- [make:command](index.md): scaffold a single `DowelCommand` subclass.
- [make:plugin](make-plugin.md): scaffold a full plugin package.
- [install](install.md): initialise a dowel consumer project structure.

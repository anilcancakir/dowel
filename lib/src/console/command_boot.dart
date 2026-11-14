/// Lifecycle boot mode an [DowelCommand] needs from the dispatcher.
///
/// Two values (none, connected). There is no `headless` mode: a
/// Magic-bound boot in CLI context would force a Flutter dependency into the
/// pure-Dart `dowel` package AND create a circular dep
/// `magic → dowel → magic`. All make:* commands are file-system-only (use
/// [FileHelper.findProjectRoot] to locate the host's `pubspec.yaml`; never
/// query `Magic.Config`); they fit `none` cleanly.
enum CommandBoot {
  /// Pure CLI. No Magic boot, no Flutter binding, no VM Service connection.
  ///
  /// Examples: `make:*`, `list`, `help`, `make:command`, `start`, `stop`,
  /// `status`, `logs`, `restart`, `doctor`, `starter:install`,
  /// `notifications:install`, `deeplink:install`, `social:install`,
  /// `mcp:install`. File-system / process-management / scaffold work only.
  none,

  /// Reads `~/.dowel/state.json` to dial the VM Service WebSocket of a
  /// running Flutter app + dispatches via `ext.*` extension calls or the
  /// `evaluate` RPC.
  ///
  /// Examples: `tapir:*`, `crumbs:*`, `tinker`. Fails fast with a clear
  /// message when no `state.json` is present (operator must run
  /// `dowel start --device=<target>` first).
  connected,
}

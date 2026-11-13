import 'dart:io';

import 'package:dowel/dowel.dart';

/// `dart run dowel <cmd>` — universal entrypoint.
///
/// Thin wrapper around [runDowel]. The helper owns auto-delegation,
/// builtin registration, base-provider wiring, auto-discovered provider
/// wiring, and the exit-code contract; see its docs for the full
/// behavior. This binary registers no extra providers — it is the
/// pure-substrate path that ships with `dowel` itself.
Future<void> main(List<String> args) async {
  exit(await runDowel(args));
}

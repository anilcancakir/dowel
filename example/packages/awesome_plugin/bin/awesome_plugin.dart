import 'dart:io';

import 'package:dowel/dowel.dart';
import 'package:awesome_plugin/cli.dart' show AwesomePluginDowelProvider;

Future<void> main(List<String> args) async {
  exit(await runDowel(
    args,
    baseProviders: [AwesomePluginDowelProvider()],
    delegateToConsumer: false,
  ));
}

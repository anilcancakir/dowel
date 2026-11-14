import 'dart:io';

import 'package:yaml/yaml.dart';

/// Whether the pubspec at [pubspecPath] already declares [name] under
/// [section] (`dependencies` or `dev_dependencies`), in any shape: a version
/// constraint, a `path:` or `git:` map, or an empty value.
///
/// The installer asks before it adds a dependency, because the editor
/// overwrites whatever is there: a caret from `dart pub add` became `any`, and
/// uninstall later removed a dependency the user had before the plugin. A
/// missing file answers false and leaves the error to the editor that writes.
bool pubspecDeclaresDependency(
  String pubspecPath,
  String name, {
  String section = 'dependencies',
}) {
  final file = File(pubspecPath);
  if (!file.existsSync()) return false;

  final document = loadYaml(file.readAsStringSync());
  if (document is! YamlMap) return false;
  final dependencies = document[section];

  return dependencies is YamlMap && dependencies.containsKey(name);
}

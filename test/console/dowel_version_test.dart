import 'dart:io';

import 'package:dowel/src/console/dowel_version.dart';
import 'package:test/test.dart';

/// `dowel --version` and the MCP handshake both report [dowelVersion]. It is a
/// literal, so the only thing keeping it honest is this test reading the
/// number out of `pubspec.yaml` instead of repeating it.
void main() {
  group('dowelVersion', () {
    test('matches the version declared in pubspec.yaml', () {
      final Match? declared = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(File('pubspec.yaml').readAsStringSync());
      expect(declared, isNotNull, reason: 'pubspec.yaml has no version: line');

      expect(
        dowelVersion,
        equals(declared!.group(1)),
        reason: 'bump dowelVersion in lib/src/console/dowel_version.dart too',
      );
    });

    test('is a release version, not a pre-release label', () {
      expect(dowelVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    });
  });
}

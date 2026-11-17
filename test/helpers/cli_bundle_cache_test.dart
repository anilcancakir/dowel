import 'dart:io';

import 'package:dowel/src/helpers/cli_bundle_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('CliBundleCache.invalidate', () {
    late Directory project;

    setUp(() {
      project = Directory.systemTemp.createTempSync('cli_bundle_cache_');
    });

    tearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });

    test('deletes only the build stamp', () {
      final dowelDir = Directory(p.join(project.path, '.dowel'))..createSync();
      final stamp = File(p.join(dowelDir.path, 'build.stamp'))
        ..writeAsStringSync('deadbeef:3.4.0');
      final binary = File(p.join(dowelDir.path, 'cli-bundle', 'dispatcher'))
        ..createSync(recursive: true);

      CliBundleCache.invalidate(project.path);

      expect(stamp.existsSync(), isFalse);
      expect(binary.existsSync(), isTrue);
    });

    test('a missing stamp is not an error', () {
      expect(() => CliBundleCache.invalidate(project.path), returnsNormally);
    });
  });
}

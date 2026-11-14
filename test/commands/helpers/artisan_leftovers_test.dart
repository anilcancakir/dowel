import 'dart:io';

import 'package:dowel/src/commands/helpers/artisan_leftovers.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('artisanLeftovers', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('artisan_leftovers_');
    });

    tearDown(() => root.deleteSync(recursive: true));

    void seed(String relative, String content) {
      File(p.join(root.path, relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    test('a dowel command whose name starts with Artisan is not one', () {
      seed(
        'lib/app/commands/artisan_bread_command.dart',
        "import 'package:dowel/dowel.dart';\n\n"
            'class ArtisanBreadCommand extends DowelCommand {}\n',
      );
      seed(
        'lib/app/commands/_index.g.dart',
        "import 'package:dowel/dowel.dart';\n"
            "import 'artisan_bread_command.dart';\n\n"
            'List<DowelCommand> get commands => <DowelCommand>[\n'
            '  ArtisanBreadCommand(),\n'
            '];\n',
      );

      expect(artisanLeftovers(root.path), isEmpty);
      expect(staleGeneratedFiles(root.path), isEmpty);
    });

    test('a command that still extends ArtisanCommand is one', () {
      seed(
        'lib/app/commands/greet_command.dart',
        'class GreetCommand extends ArtisanCommand {}\n',
      );

      expect(artisanLeftovers(root.path), <String>[
        'lib/app/commands/greet_command.dart',
      ]);
    });

    test('an import of the removed package is one', () {
      seed(
        'lib/app/commands/_index.g.dart',
        "import 'package:fluttersdk_artisan/artisan.dart';\n",
      );

      expect(staleGeneratedFiles(root.path), <String>[
        'lib/app/commands/_index.g.dart',
      ]);
    });

    test('runArtisan in the dispatcher is one', () {
      seed(
        'bin/dispatcher.dart',
        'void main(List<String> a) => runArtisan(a);\n',
      );

      expect(staleGeneratedFiles(root.path), <String>['bin/dispatcher.dart']);
    });
  });
}

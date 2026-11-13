import 'package:awesome_plugin/cli.dart';
import 'package:test/test.dart';

void main() {
  group('AwesomePluginDowelProvider', () {
    test('registers install + uninstall commands', () {
      final provider = AwesomePluginDowelProvider();
      final commands = provider.commands();

      expect(commands.length, 2);
    });
  });
}

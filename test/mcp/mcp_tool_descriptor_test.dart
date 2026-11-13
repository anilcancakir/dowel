import 'package:test/test.dart';

import 'package:dowel/dowel.dart';

void main() {
  group('McpToolDescriptor', () {
    const descriptor = McpToolDescriptor(
      name: 'tapir_tap',
      description: 'Tap a widget by semantic label.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'label': {'type': 'string'},
        },
        'required': ['label'],
      },
      extensionMethod: 'ext.tapir.tap',
    );

    test('constructor populates all 4 fields', () {
      expect(descriptor.name, 'tapir_tap');
      expect(descriptor.description, 'Tap a widget by semantic label.');
      expect(descriptor.inputSchema, {
        'type': 'object',
        'properties': {
          'label': {'type': 'string'},
        },
        'required': ['label'],
      });
      expect(descriptor.extensionMethod, 'ext.tapir.tap');
    });

    test(
        'toJson includes name + description + inputSchema, excludes extensionMethod',
        () {
      final json = descriptor.toJson();

      expect(json.containsKey('name'), isTrue);
      expect(json.containsKey('description'), isTrue);
      expect(json.containsKey('inputSchema'), isTrue);
      expect(json.containsKey('extensionMethod'), isFalse);

      expect(json['name'], 'tapir_tap');
      expect(json['description'], 'Tap a widget by semantic label.');
      expect(json['inputSchema'], descriptor.inputSchema);
    });

    test('toString is useful for collision diagnostics', () {
      final str = descriptor.toString();

      expect(str, contains('tapir_tap'));
      expect(str, contains('ext.tapir.tap'));
    });
  });
}

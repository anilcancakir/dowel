# Testing a dowel command

Read this when writing or fixing a test for a `DowelCommand` or an installer operation.

Test a command without a process, a VM or a terminal: build a `DowelContext.bare` over a `MapInput` and a `BufferedOutput`, call `handle`, assert on the exit code and the captured output.

```dart
import 'package:dowel/dowel.dart';
import 'package:test/test.dart';

final class GreetCommand extends DowelCommand {
  @override
  String get signature => 'greet {name} {--shout}';

  @override
  String get description => 'Greet a person by name.';

  @override
  CommandBoot get boot => CommandBoot.none;

  @override
  Future<int> handle(DowelContext context) async {
    context.output.success('Hello, ${context.input.argument('name') ?? 'world'}');
    return 0;
  }
}

void main() {
  test('greet says hello', () async {
    final command = GreetCommand();
    final output = BufferedOutput();
    final context = DowelContext.bare(
      MapInput(
        const <String, dynamic>{'shout': false},
        positional: const ['Ada'],
        signature: command.parsedSignature,
      ),
      output,
    );

    expect(await command.handle(context), 0);
    expect(output.content, contains('Hello, Ada'));
  });
}
```

An installer is tested the same way against `InstallContext.test` with an `InMemoryFs`: stage the operations, assert on `pendingOps`, and commit only when the test is about the written content.

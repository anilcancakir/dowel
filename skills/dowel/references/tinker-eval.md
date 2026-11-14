# dowel_tinker reference

`dowel_tinker { eval: "<expr>" }` evaluates one Dart expression in the running app's root library through the VM Service `evaluate` RPC; the CLI form is `./bin/dowel tinker --eval=<expr>`. The handler is `lib/src/commands/tinker_command.dart`, the VM client `lib/src/vm/vm_service_client.dart`. It needs a session with a `vmServiceUri`.

## Contents

- [Expression rules](#expression-rules)
- [Reading the result](#reading-the-result)
- [What a failure looks like](#what-a-failure-looks-like)
- [Recipes](#recipes)
- [When not to use tinker](#when-not-to-use-tinker)
- [dowel_tinker and tapir_evaluate](#dowel_tinker-and-tapir_evaluate)

## Expression rules

- **One expression.** The VM compiles an expression, not a program: a trailing `;`, several statements, an `import` or a declaration fail with compile error code 113. Collapse statements into a closure, `(() { var x = 1; return x + 1; })()`, or use a cascade or the comma operator.
- **`await` works.** When the source contains the text `await`, dowel wraps it as `(() async => <expr>)()` (`VmServiceClient.evaluate`). The check is a substring match, so the word inside a string literal triggers the wrap too.
- **Scope is the root library**, usually `lib/main.dart`: its top-level symbols and whatever it imports, public names only. There is no `this`, no local variable and no symbol from a library the root does not import. A host app's singleton, top-level service or container lookup works as long as the root library reaches it.
- **The main isolate is read on every call**, so a hot restart is transparent. The MCP server keeps its VM connection for the life of the process: after a device change or a `dowel_stop` and `dowel_start`, reconnect the MCP client if calls fail.
- `dowel_tinker` is one shot with no streaming. Loop in the agent, not in the expression.

## Reading the result

| Result | Rendered as |
|---|---|
| Null, bool, number | `null`, `true`, `42` |
| String | `"quoted"` (double quotes) |
| Any other object | `<ClassName#id>` |
| `ErrorRef` (the expression threw) | `Error: <message>` |

Append `.toString()` inside the expression to read a non-primitive: `MyService.instance.state` gives `<MyState#a3f9>`, `MyService.instance.state.toString()` gives `"MyState(loaded: true, count: 12)"`. Override `toString()` on state types so the dump says something. A list or map prints as `<ClassName#id>` too, so convert it first: `p.getKeys().toList().toString()`.

## What a failure looks like

The result text starts with `` # `dowel tinker` exit N ``, and `isError` is set when `N` is not 0.

| Case | Text | Exit |
|---|---|---|
| Compile error | `[ERROR] evaluate: (113) <compiler message>` | 1 |
| The expression threw at runtime | `Error: <message>` | 0, so `isError` is false: read the text |
| No session, or the VM Service is unreachable | `### Error` then `Not connected to a running Flutter app. Run ...` | error |

For a compile error, rewrite as one valid expression. For a runtime error, fix the app code or the expression. A stale isolate after a hot restart recovers on the next call; if it does not, call `dowel_hot_restart`.

## Recipes

Replace `MyService` and `MyEvent` with the host app's own names.

```text
dowel_tinker { eval: "WidgetsBinding.instance.lifecycleState.toString()" }
dowel_tinker { eval: "PaintingBinding.instance.imageCache.currentSize" }
dowel_tinker { eval: "WidgetsBinding.instance.platformDispatcher.locale.toString()" }
dowel_tinker { eval: "MyService.instance.state.toString()" }
dowel_tinker { eval: "await MyService.instance.refresh()" }
dowel_tinker { eval: "await SharedPreferences.getInstance().then((p) => p.getKeys().toList().toString())" }
dowel_tinker { eval: "(MyService.instance..reset()).state.toString()" }
dowel_tinker { eval: "MyService.instance.notify('boot'), 'notified'" }
```

The cascade returns the receiver, so the wrapped parentheses plus `.state.toString()` reads the state after a synchronous side effect. The comma operator evaluates both sides and returns the right one, which makes a `void` call self-describing. To compare before and after an action, evaluate the same read expression on either side of it.

## When not to use tinker

- Widget tree, gestures, waiting on UI state: the `tapir` skill's tools; tinker has no `BuildContext` and no hit testing.
- HTTP, log and exception buffers: the `crumbs` skill's tools.
- Several statements with control flow: a test under `test/`, run with `dart test`.

## dowel_tinker and tapir_evaluate

Both evaluate against the root library and both wrap `await`. `tapir_evaluate` comes from the `tapir` plugin (dispatcher entry only) and returns `{expression, result}`; its failures are `### Error` text starting `Runtime exception:`, `Expression compilation error:` or `Isolate sentinel encountered (kind: ...)`. Use `dowel_tinker` for inspection and triggers; its output goes through the `Tinker.casters` chain, which a host integration can extend.

import '../vm/vm_service_client.dart';
import 'dowel_input.dart';
import 'dowel_output.dart';
import 'dowel_registry.dart';

/// Execution context handed to every [DowelCommand.handle].
///
/// Constructed by [DowelApplication.dispatch] based on the command's
/// [CommandBoot] declaration, either bare or connected to a running app.
///
/// [registry] is populated by [DowelApplication.dispatch] so command
/// handlers can call `ctx.registry?.find('cmd')?.handle(ctx)` for in-process
/// command chaining. It is nullable for backward compatibility with bare
/// contexts constructed in tests or outside [DowelApplication.dispatch].
class DowelContext {
  DowelContext.bare(this.input, this.output, {this.registry}) : vmClient = null;

  DowelContext.connected(
    this.input,
    this.output,
    VmServiceClient client, {
    this.registry,
  }) : vmClient = client;

  final DowelInput input;
  final DowelOutput output;

  /// Available only when the command's boot is [CommandBoot.connected].
  final VmServiceClient? vmClient;

  /// The application's command registry.
  ///
  /// Non-null when constructed by [DowelApplication.dispatch]; null when
  /// constructed as a bare context (e.g. in tests). Use the null-safe `?.`
  /// operator: `ctx.registry?.find('plugins:refresh')?.handle(ctx)`.
  final DowelRegistry? registry;

  /// Calls a VM Service extension on the running app's main isolate.
  /// Throws [StateError] when the context is not connected.
  Future<T> callExtension<T>(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final client = vmClient;
    if (client == null) {
      throw StateError(
        'DowelContext.callExtension called from a non-connected context. '
        'The command must declare `boot => CommandBoot.connected`.',
      );
    }
    final isolateId = await client.getMainIsolateId();
    return await client.callServiceExtension<T>(
      method,
      isolateId: isolateId,
      params: params,
    );
  }

  /// Evaluates a Dart expression in the running app's root library.
  /// Throws [StateError] when the context is not connected.
  Future<dynamic> evaluate(String expression) async {
    final client = vmClient;
    if (client == null) {
      throw StateError(
        'DowelContext.evaluate called from a non-connected context. '
        'The command must declare `boot => CommandBoot.connected`.',
      );
    }
    final isolateId = await client.getMainIsolateId();
    return await client.evaluate(isolateId, expression);
  }
}

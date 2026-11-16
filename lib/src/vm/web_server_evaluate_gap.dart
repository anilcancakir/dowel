/// The one-line explanation for an `evaluate` that dwds cannot answer, or
/// `null` when [error] is anything else.
///
/// `start --cdp-port` runs `flutter run -d web-server` with a separately
/// launched Chrome. The dwds service behind that device has no `evaluate`
/// (no browser tab is attached as a debug connection), so the VM Service
/// answers with a `NoSuchMethodError` from its `WebSocketProxyService`. The
/// chrome device has no such gap, so the message names it instead of passing
/// the stack trace through.
///
/// The match is on dwds's error text. A wording change on dwds's side falls
/// back to the raw error, which is safe: the caller prints [error] as it was.
String? webServerEvaluateGapMessage(Object error) {
  final String text = '$error';
  final bool isGap =
      text.contains('WebSocketProxyService') &&
      text.contains("has no instance method 'evaluate'");

  if (!isGap) return null;

  return 'evaluate is not available on a web-server session (the Flutter '
      'web-server device has no debug connection to a browser tab). Run '
      '`dowel stop`, then `dowel start --device=chrome` without --cdp-port '
      'to evaluate; --cdp-port keeps the CDP commands and gives up '
      'evaluate.';
}

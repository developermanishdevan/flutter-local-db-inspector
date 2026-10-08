/// Normalizes a VM service URI as printed by `dart run`/`flutter run`
/// (`http://127.0.0.1:8181/abc=/`) into its WebSocket form
/// (`ws://127.0.0.1:8181/abc=/ws`). WebSocket URIs are returned unchanged.
Uri vmServiceWebSocketUri(String uri) {
  final parsed = Uri.parse(uri.trim());
  if (parsed.scheme == 'ws' || parsed.scheme == 'wss') return parsed;
  final path = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
  return parsed.replace(
    scheme: parsed.scheme == 'https' ? 'wss' : 'ws',
    path: '${path}ws',
  );
}

# VS Code extension

Source: [`integrations/vscode/flutter-db-inspector`](../integrations/vscode/flutter-db-inspector). User documentation is in its [README](../integrations/vscode/flutter-db-inspector/README.md).

## Structure

```
src/
  extension.ts                 activation and wiring
  connection/
    connectionManager.ts       state machine: connect, hot restart, stop (no VS Code dependency)
    wsTransport.ts             VM service JSON-RPC over WebSocket
    dapTransport.ts            fallback through the Dart debug adapter (callService)
    sessionWatcher.ts          discovers Dart-Code debug sessions (dart.debuggerUris)
  services/
    inspectorClient.ts         typed protocol client; the only way UI reaches the app
    exporter.ts                streamed JSON/CSV/SQL export
    queryStore.ts              history and saved queries (workspace state)
  providers/                   database tree, queries tree, status bar
  panels/                      webview host; every write is confirmed here
```

The webview UI itself (data grid, value inspector, row form, SQL console, stats) lives in [`shared/web-ui`](../shared/web-ui). It is shared with the Android Studio and DevTools integrations, and `esbuild.mjs` builds it into `dist/webview.js` and `dist/webview.css`.

The tree and commands are native VS Code UI. Webviews are used only for the data grid, schema, SQL console and statistics. Webviews never talk to the app directly. They send requests to the extension host, which validates them and shows native confirmation dialogs for destructive operations.

## Development

```bash
npm install
npm run build            # or: npm run watch, then F5 ("Run Extension")
npm run test:unit        # pure logic
npm run test:integration # against a real Dart VM running the demo server
FDI_FLUTTER_DEVICE=macos npm run test:integration   # also a real Flutter app, including hot restart
npm run test:vscode      # inside a VS Code instance (set ELECTRON_RUN_AS_NODE= when launched from VS Code)
npx vsce package --no-dependencies
```

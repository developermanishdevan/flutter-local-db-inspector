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

## Publishing

The extension ID is `developer-manishdevan.flutter-db-inspector`. It is published to the [Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=developer-manishdevan.flutter-db-inspector) and [Open VSX](https://open-vsx.org/extension/developer-manishdevan/flutter-db-inspector) (used by Cursor, VSCodium, Windsurf and Gitpod).

### One-time setup

1. **Marketplace publisher**: sign in at <https://marketplace.visualstudio.com/manage> with a Microsoft account and create the publisher with ID **`developer-manishdevan`**, which must match `"publisher"` in `package.json`.
2. **Marketplace token**: at <https://dev.azure.com> go to *User settings → Personal access tokens → New token*. Set *Organization* to **All accessible organizations** and *Scopes* to **Custom defined → Marketplace → Manage**. Add it as the GitHub repository secret `VSCE_PAT`.
3. **Open VSX** (optional): sign in at <https://open-vsx.org> with GitHub, sign the Eclipse publisher agreement, create an access token, then run `npx ovsx create-namespace developer-manishdevan -p <token>` once. Add the token as the secret `OVSX_PAT`.

### Release

1. Bump `version` in `package.json` and add an entry to `CHANGELOG.md`.
2. Check the package locally: `npm run package`, then install it with `code --install-extension flutter-db-inspector-<version>.vsix`.
3. Commit, then tag and push:

   ```bash
   git tag vscode-v<version>
   git push origin vscode-v<version>
   ```

   [`release-vscode.yml`](../.github/workflows/release-vscode.yml) checks that the tag matches `package.json`, runs the type check and unit tests, packages the `.vsix`, publishes it to both registries, and attaches it to a GitHub release. Running the workflow manually from the Actions tab only builds the `.vsix`, unless you tick *Publish*.

To publish from your machine instead: `npx vsce login developer-manishdevan`, then `npm run publish:vsce`, and `OVSX_PAT=<token> npm run publish:ovsx`.

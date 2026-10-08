# Shared web UI

The data UI used by the Flutter DB Inspector IDE integrations: data grid, filter/sort/search/paging, value inspector, row form, schema view, SQL console and statistics. It is plain TypeScript and DOM, with no framework.

It runs in three hosts:

| Host | How it is loaded | Transport ([`transport.ts`](src/transport.ts)) | Theme |
|---|---|---|---|
| VS Code | webview, built by the extension's `esbuild.mjs` | `acquireVsCodeApi()` | VS Code's `--vscode-*` tokens |
| Android Studio | JCEF browser loading `dist/index.html` | the plugin injects `window.fdiHost.postMessage(json)` | [`theme.css`](src/theme.css), `data-theme` set by the plugin |
| DevTools | iframe loading `dist/index.html` | `window.parent.postMessage` (only messages from the parent are accepted) | [`theme.css`](src/theme.css), `data-theme` set by the extension |

VS Code uses panel mode. Android Studio and DevTools use app mode.

## Host contract

The UI never talks to the app. It exchanges JSON messages with its host, defined in the VS Code extension's [`messages.ts`](../../integrations/vscode/flutter-db-inspector/src/panels/messages.ts). Hosts deliver messages as `window` "message" events.

### Panel mode (VS Code)

One view per page: `init {view: 'table' | 'sql' | 'stats', database, table, ...}`. The host runs every request (`rows`, `update`, `delete`, `sql`, ...), and shows native confirmations and native copy/save/export.

### App mode (Android Studio, DevTools)

One page with the database tree, closeable tabs (data/schema, SQL console with history and saved queries, statistics), dialogs and toasts. The UI turns its own requests into protocol calls and asks for confirmation in the page, so the host is small:

**Host → UI**

| Message | When |
|---|---|
| `init {view: 'app', host, pageSize, theme?, confirmCellEdits?, historyLimit?}` | after the UI sends `ready`. To avoid a light flash before it, load the page as `index.html?theme=dark`. |
| `connection {state, message?}` | right after `init`, then on every change. States: `connecting`, `connected`, `reconnecting`, `disconnected`, `error`. A change to `connected` reloads everything (e.g. after hot restart). |
| `event {name, data?}` | the app posted `flutter_db_inspector.databasesChanged`: the tree reloads |
| `theme {theme: 'light' \| 'dark'}` | the IDE / DevTools theme changed |
| `open {target: {view, databaseId, table?, tab?, sql?}}` | a native action ("SQL Console", ...) |
| `reload` | native Refresh |
| `result {id, ok: true, result}` / `result {id, ok: false, error: {code, message, details?}}` | answer to a request |

**UI → host**: `ready`, `error {message}` (log it), and `request {id, request}`, where `request.op` is one of:

| op | Host does |
|---|---|
| `call {method, params}` | sends the protocol request to the app (`ext.flutter_db_inspector.request` with `{"method", "params"}`), answers `result` with the response's `result`, or `ok: false` with the protocol error's `code`, `message` and `details` |
| `copy {text, label?}` | writes the clipboard |
| `saveFile {name, text? \| base64?}` | asks where to save (`name` is the suggested file name), writes UTF-8 `text` or decoded `base64`, and answers `{}` or `{cancelled: true}` |
| `notify {message, level?}` | optional native notification |

Unknown ops should be answered with `ok: false` (code `INVALID_REQUEST`), never ignored, so the UI does not wait forever.

SQL history and saved queries are kept in the page's `localStorage`, never in the app.

The protocol types and value helpers, client, exporter, query store and labels are imported from the VS Code extension through the `@protocol/*`, `@messages`, `@services/*` and `@labels` aliases in [`tsconfig.json`](tsconfig.json). The extension also runs them on Node.

## Development

```bash
npm install
npm run typecheck
npm run build             # dist/ for Android Studio and DevTools (add :production to minify)
```

`styles.css` uses VS Code's theme token names. Any new `--vscode-*` token it starts using must also be added to `theme.css`, in both the light and the dark block.

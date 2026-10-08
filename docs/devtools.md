# DevTools extension

Flutter DB Inspector ships a [DevTools extension](https://docs.flutter.dev/tools/devtools/extensions). It is bundled inside the `flutter_db_inspector` package (`extension/devtools/`), so every app that depends on the package gets it automatically. Nothing else to install.

## Opening it

1. Add `flutter_db_inspector` (and an adapter) to your app and call `DbInspector.initialize()` / `registerDatabase()` (see [getting_started.md](getting_started.md)).
2. Run the app in debug or profile mode (`flutter run`, or from your IDE).
3. Open DevTools (the link printed by `flutter run`, or **Open DevTools** in VS Code / Android Studio).
4. Select the **flutter_db_inspector** tab. The first time, DevTools asks you to enable the extension; choose **Enable**.

The extension uses the VM service connection DevTools already has. It never reads database files; every request goes through `ext.flutter_db_inspector.request` (see [protocol.md](protocol.md)).

## Web UI and classic UI

The extension shows the same UI as the Android Studio plugin: the shared web UI from [`shared/web-ui`](../shared/web-ui/README.md) (database tree, closeable data / schema / SQL / statistics tabs, value inspector, row form, export), loaded in an iframe at `web_ui/index.html` next to the extension. SQL history and saved queries are kept in the browser's `localStorage`.

The original Flutter UI described below is still available: **Classic UI** at the bottom right switches to it (**Switch to the new UI** switches back), and the choice is remembered in `localStorage`. `?ui=classic` or `?ui=web` in the extension URL overrides it.

## Features (classic UI)

| Area | What you get |
|---|---|
| Sidebar | **DATABASES** tree: database (engine label, read-only badge) ▸ Tables / Views / Collections / Boxes / Stores (tables first) with row counts ▸ Indexes ▸ Triggers. Status line `● Connected` / `Reconnecting…` / `Disconnected`. A **Filter tables…** field above the tree narrows it by name as you type (matching indexes and triggers too) and expands every match. |
| Tabs | **Data · Schema · SQL · Statistics**. SQL appears only when the adapter advertises the `sql` capability. Wording follows the data model: rows, objects or entries. |
| Data | Server-side paging (25/50/100, capped by the app's `maxPageSize`), debounced search (`search` capability), filter builder (`filter`), click a header to sort asc → desc → off (`sort`), resizable columns (drag the header edge, double-click to reset), row numbers, horizontal and vertical scrolling. |
| Cells | `NULL` in italics, masked values as `••••••••`, `BLOB 2.0 MB`, truncated text with `…`, compact JSON, exact 64-bit integers. |
| Editing | Double-click, Enter or F2 edits a cell inline when the adapter supports `update`, the row has a key and the column is not generated, masked, binary, truncated or the key of a key-value store. Input is parsed by the column's value type. Context menu: copy cell, copy row as JSON (exact big integers), view value, edit, set NULL, duplicate, delete (with confirmation). **Add** opens a form; **Clear** deletes every record after confirming the count. |
| Value inspector | Side panel with Pretty/Raw JSON, Copy, **Load full value** for truncated text (streamed with `value.read`), hex preview of blobs (first 64 KB on demand) and an editor with **Set NULL**. Masked values are never shown. |
| SQL | Monospace editor, **Run** (Ctrl/Cmd+Enter, runs the selection if any), **Cancel** (stops waiting), results grid, elapsed time, row count, truncation warning, errors. Statements the app cannot prove read-only ask *"This query may modify application data."* → **Cancel** / **Execute**, and are resent with `allowWrite: true` only after you confirm. Query history (per database, re-run with one click) is kept client-side in the browser's `localStorage`, never in the app. |
| Schema | Columns (name, declared type, value type, PK, nullable, default, notes such as auto / generated / masked), foreign keys (click to open the referenced table), indexes, triggers and the DDL. With no table selected: the database overview. |
| Statistics | Size, entity / index / trigger counts, total records, engine metadata and the largest entities. |
| Hot restart | The extension notices the new isolate and reconnects by itself; the tree, the open table (with its page, search, filters and sort) and statistics reload without any action. Requests made during the restart wait for the app instead of failing. |

**Keyboard:** arrows move in the grid, Enter/F2 edit, Esc cancels or closes the value panel, Delete deletes the row, Ctrl/Cmd+C copies the cell (add Shift for the row as JSON), Shift+F10 opens the context menu, Ctrl/Cmd+F focuses search, Ctrl/Cmd+R (or F5) refreshes. In the tree: Up/Down, Right/Left to expand/collapse, Enter to open. All controls have tooltips and semantics labels, and the UI uses the DevTools theme in light and dark mode.

## Architecture

```
DevTools ── serviceManager (VmService) ──► ConnectionManager (services/connection_manager.dart)
                                                │  attaches the VmService to
                                                ▼
                                   InspectorConnection   (package:flutter_db_inspector_client)
                                   isolate discovery · handshake · hot restart · timeouts
                                                │
                                   InspectorClient (typed protocol calls)
                                                │
          InspectorController / TableController / SqlController (ChangeNotifier state)
                                                │
                pages/ (home, database, table, schema, query, stats) + widgets/   ← classic UI

          web_ui/ WebUiBridge (bridge.dart) ── postMessage ──► iframe web_ui/index.html (shared/web-ui)
```

- Web UI: `web_ui/platform_web.dart` creates the iframe (`HtmlElementView`) and only accepts `message` events whose source is that iframe; `WebUiBridge` implements the app-mode host contract of [`shared/web-ui/README.md`](../shared/web-ui/README.md): `ready` → `init {view: 'app', host: 'devtools', pageSize: 50, theme}` + `connection`; connection changes, `databasesChanged` events and DevTools theme changes are forwarded; `call` goes to `InspectorConnection.request` (reads are retried after a hot restart), `copy` and `notify` go through DevTools (`extensionManager`), `saveFile` downloads the file from the extension page, and any other op is answered with `INVALID_REQUEST`.

- `packages/flutter_db_inspector_client` is a pure Dart package (no Flutter): `InspectorConnection` is a port of the VS Code `ConnectionManager` built on `package:vm_service`; `InspectorClient` returns `flutter_db_inspector_protocol` models; `WireValue` / `WireValues` implement the display and input rules shared with the VS Code client. Any Dart tool can reuse it (`InspectorConnection.connectUri(uri)`).
- `packages/flutter_db_inspector_devtools` is the extension's Flutter web app. Only `services/connection_manager.dart` sees the VM service; widgets use `InspectorClient` exclusively.
- The built app lives in `packages/flutter_db_inspector/extension/devtools/build`, next to `config.yaml`, with the web UI in `build/web_ui/`. Both are committed; the copy in the source package (`web/web_ui/`) is generated and ignored by git.

## Developing the extension

```bash
cd packages/flutter_db_inspector_devtools
flutter pub get
tool/sync_web_ui.sh               # builds shared/web-ui (npm) and copies dist/ to web/web_ui/

# Simulated DevTools environment in Chrome. Paste the VM service URI of a
# running app, e.g. the device-free demo server:
#   (cd ../flutter_db_inspector_sqlite && dart run --enable-vm-service=0 example/inspector_server.dart --restartable)
flutter run -d chrome --dart-define=use_simulated_environment=true

flutter analyze --fatal-infos
flutter test                      # web UI bridge, controllers, grid, tree, value parsing, pages (fake backend)

# Rebuild the shipped extension (run tool/sync_web_ui.sh first) and validate it
dart run devtools_extensions build_and_copy --source=. --dest=../flutter_db_inspector/extension/devtools
dart run devtools_extensions validate --package=../flutter_db_inspector
```

The client package has unit tests and end-to-end tests against the real demo server (a Dart VM with the inspector and a seeded SQLite database), including hot restart and app shutdown:

```bash
(cd packages/flutter_db_inspector_sqlite && dart pub get)   # once: the demo server
cd packages/flutter_db_inspector_client
dart pub get && dart test         # dart test -x e2e skips the demo-server suite
```

To try the real extension in DevTools before publishing, point an app at your local checkout of `flutter_db_inspector` (path dependency), run it and open DevTools as above.

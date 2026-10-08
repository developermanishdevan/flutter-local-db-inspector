# Android Studio / IntelliJ plugin

The **Flutter DB Inspector** plugin adds a *Flutter DB* tool window to Android Studio and IntelliJ IDEA (2025.1 / build 251 and newer). It speaks the same [protocol](protocol.md) as the VS Code and DevTools clients. It never reads database files and has no database logic: every request goes to the app's `flutter_db_inspector` package through the Dart VM service.

Source: [`integrations/android-studio/flutter-db-inspector`](../integrations/android-studio/flutter-db-inspector).

## Install

1. Build the plugin zip (or download the `flutter-db-inspector-intellij` artifact from CI):

   ```bash
   cd integrations/android-studio/flutter-db-inspector
   ./gradlew buildPlugin        # → build/distributions/flutter-db-inspector-1.0.0.zip
   ```

2. In the IDE, open **Settings ▸ Plugins ▸ ⚙ ▸ Install Plugin from Disk…**, pick the zip, and restart if asked.

The plugin depends only on `com.intellij.modules.platform`. It doesn't need the Flutter or Dart plugins.

## Use

1. Set up the app as described in [getting_started.md](getting_started.md) (`DbInspector.initialize()` + `registerDatabase`).
2. Run or debug the app from a Flutter or Dart run configuration. The plugin finds the VM service URI in the run console and connects to the newest app. It disconnects when that process stops.
3. Open **View ▸ Tool Windows ▸ Flutter DB**, or **Tools ▸ Flutter DB Inspector ▸ Open Inspector**.

If the app was started from a terminal (`flutter run`, `dart run --enable-vm-service`), use **Tools ▸ Flutter DB Inspector ▸ Connect to VM Service URI…** and paste the `http://127.0.0.1:PORT/TOKEN=/` URI, a `ws://…/ws` URI or a DevTools link.

Without a device, run the demo server and connect to the URI it prints:

```bash
dart pub get                                   # repository root
cd packages/flutter_db_inspector_sqlite
dart run --enable-vm-service example/inspector_server.dart
```

## Web UI and Swing fallback

By default the tool window shows the **shared web UI** ([`shared/web-ui`](../shared/web-ui), the same UI as the VS Code extension and DevTools) in an embedded Chromium browser (JCEF), under the native toolbar (Connect, Refresh, SQL Console, Disconnect). It follows the IDE's light or dark theme, and takes rows per page, *confirm cell edits* and the history size from the plugin settings. In this UI, SQL history and saved queries are kept by the page (browser storage), not in the project's workspace file.

The plugin uses the classic **Swing UI** described below instead when the IDE has no JCEF support, when *Settings ▸ Tools ▸ Flutter DB Inspector ▸ Use the web UI* is off (the tool window switches as soon as you apply), or when the plugin was built with `-PskipWebUi`.

## Features (Swing UI)

- **Status and toolbar**: `● Connected · <app>`, *Connecting…*, *Reconnecting…* or the error. Toolbar actions are Connect, Refresh, SQL Console and Disconnect.
- **Database tree**: *DATABASES ▸ database* (engine label such as SQLite, Drift or Hive, plus a read-only badge) *▸ Tables / Collections / Boxes / Stores, then Views, Indexes and Triggers ▸ entities* with row counts. The **Filter tables…** field above the tree narrows it by name as you type; IntelliJ speed search (just start typing in the tree) also jumps between matches.
  - Double-click or Enter opens an entity.
  - Entity context menu: Open Data, Open Schema, Export…, Clear… (when the database supports it and the entity is writable), Copy Name.
  - Database context menu: SQL Console (SQL databases), Statistics, Export Database…, Refresh, Copy Name.
- **Entity tab** with **Data** and **Schema** (or *Structure*) sub-tabs:
  - Server-side paging (25, 50 or 100 rows), debounced search, a filter row builder (`Where column operator value and …`) and sorting by clicking a column header. Each one appears only when the database supports it.
  - Typed cells: `NULL` in grey italics, masked values as `••••••••`, BLOB sizes, truncated text with `…`, compact JSON and exact 64-bit integers.
  - Inline editing (double-click, Enter or F2), with the same rules as VS Code. A cell is editable only when the database supports `update`, the row has a key, and the column isn't generated, masked, truncated or a `key`-addressed primary key.
  - Cell menu: Copy Cell, Copy Row as JSON (exact big integers), Copy Row as CSV, View Value, Edit Cell, Set NULL, Duplicate, and Delete (with confirmation). Shortcuts: Ctrl/Cmd+C, Ctrl/Cmd+Shift+C, Delete, Ctrl/Cmd+F, Ctrl/Cmd+R or F5.
  - **Add row** dialog: skips generated columns, lets you leave auto-increment and default columns empty, and has a NULL checkbox for each column.
  - **Clear** asks for confirmation and shows the record count. **Export** writes JSON, CSV or SQL (SQL only for relational databases) in a cancellable background task. It pages through the rows, completes truncated values and BLOBs with `value.read`, and exports masked values as `null`.
  - **Value inspector** (side panel): JSON pretty or raw, copy, load the full value of truncated text, edit, set NULL, BLOB hex preview, and save to a file in chunks.
  - **Schema**: columns, row key, foreign keys (double-click opens the referenced table), indexes, triggers and the DDL.
- **SQL console** (databases with the `sql` capability):
  - Run with Ctrl/Cmd+Enter (runs the selection if there is one) and Cancel.
  - Results grid with elapsed time, row count and a truncation notice.
  - Statements that may write show *"This query may modify application data."* with **[Cancel] [Execute]**, then re-run with `allowWrite`.
  - History and saved queries are stored by the IDE in the project's workspace file, never in the app.
- **Statistics**: size, entity, index and record counts, and the largest entities.
- **Hot restart**: the plugin reconnects automatically and reloads open tabs. Requests made during a restart wait for the app to come back. Reads interrupted by the restart are retried. Writes are reported so you can try again.
- **Settings** (*Settings ▸ Tools ▸ Flutter DB Inspector*): use the web UI, auto-connect, request timeout, rows per page, confirm cell edits, and history size.

## Architecture

```
src/main/kotlin/com/manishdevan/flutterdb/
├── Plugin.kt            constants, icons, notifications, tool window access
├── toolwindow/          FlutterDbToolWindowFactory (web UI or Swing), InspectorToolWindowPanel (status, tree | closeable tabs)
├── actions/             Open Inspector, Connect…, Refresh, SQL Console, Disconnect
├── service/             InspectorService (project: connection, client, databases model, discovery)
│                        InspectorClient, Exporter, QueryStore + InspectorSettings (PersistentStateComponent)
├── protocol/            constants, models + tolerant Gson parsing, WireValue, Values (display/parse/copy/CSV/SQL)
├── connection/          VmServiceClient (java.net.http WebSocket JSON-RPC), ConnectionManager, VmServiceUri,
│                        RunConsoleDiscovery (ExecutionManager.EXECUTION_TOPIC listener)
├── ui/web/              WebInspectorPanel (JCEF browser), WebUiBridge (host side of the web UI messages),
│                        WebUiRequestHandler + WebUiResources (serve the bundled UI)
└── ui/                  DatabaseTreePanel, EntityPanel, DataTablePanel, SchemaPanel, SqlConsolePanel,
                         ValueInspectorPanel, AddRowDialog, StatisticsPanel, EntityOperations (clear / export)
```

- **Web UI host**: the Gradle task `buildWebUi` builds `shared/web-ui` and bundles its `dist/` in the plugin jar under `web-ui/`. `WebUiRequestHandler` serves those files to JCEF from the private origin `https://fdi-web-ui/` (nothing is extracted to disk, and the page's CSP `'self'` covers them). After each page load the plugin injects `window.fdiHost.postMessage(json)`, backed by a `JBCefJSQuery`, and answers with `window.postMessage(...)`. `WebUiBridge` implements the app-mode host contract in [`shared/web-ui/README.md`](../shared/web-ui/README.md): `call` goes to `ConnectionManager.request`, `copy` to the clipboard, `saveFile` to a save dialog, `notify` to an IDE notification. Connection changes, the app's `databasesChanged` event and theme changes are pushed to the page. Native Refresh sends `reload`; SQL Console sends `open`.

- `ConnectionManager` is a port of the VS Code state machine. It scans isolates with `getVM`/`getIsolate` (`extensionRPCs`), does the `inspector.status` handshake with a version check, handles `IsolateExit` → `ServiceExtensionAdded` reconnects, makes requests wait during a reconnect, and maps errors. Its state lives on one serial coroutine thread, so it behaves like the JavaScript event loop. It has no IntelliJ dependency.
- Network work runs on coroutines (`Dispatchers.IO`) and background tasks. UI updates run on the EDT. Every panel is a `Disposable` that cancels its coroutines.
- `protocol/Values.kt` ports `values.ts`, so display, copy, CSV and SQL output match the VS Code extension. Numbers keep their exact JSON text, so 64-bit integers never lose precision.
- The UI uses JB colors, `JBUI` and platform icons, with no hard-coded colors, so it works in light and dark themes.

## Development

Requirements: JDK 21 (Android Studio's bundled JBR works), Node.js 20+ to build the web UI (the build runs `npm ci` in `shared/web-ui` when `node_modules` is missing, then `npm run build:production`), and Dart for the integration test. The Gradle wrapper is checked in. Without Node.js, pass `-PskipWebUi`: the plugin is built without the web UI and always shows the Swing UI.

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"   # macOS example
cd integrations/android-studio/flutter-db-inspector
./gradlew build                            # web UI + compile + all tests
./gradlew build -PskipWebUi                # without Node.js (Swing UI only)
./gradlew buildPlugin                      # build/distributions/*.zip
./gradlew verifyPluginProjectConfiguration
./gradlew verifyPlugin                     # Plugin Verifier against the local IDEs (see build.gradle.kts)
./gradlew runIde                           # sandbox IDE with the plugin
```

- **Target platform**: by default the build compiles against a local IDE (`platformLocalPath` in `gradle.properties`, `/Applications/Android Studio.app`), which avoids a ~1 GB download. If that path doesn't exist, or you pass `-PplatformLocalPath=`, it downloads IntelliJ IDEA Community `platformVersion` (2025.1.3), as CI does.
- **Compatibility**: `since-build` is 251 and there's no `until-build`. The Kotlin API version is pinned to 2.1, the stdlib bundled with 2025.1. `verifyPlugin` checks the plugin against Android Studio (253) and IntelliJ IDEA CE 2025.1.3 (251) when they're installed.
- **Tests** (`src/test/kotlin`):
  - Unit tests for values, URIs and console discovery, protocol parsing, query store and exporter, and the web UI bridge (request dispatch, message shapes) and resource serving (paths, MIME types, theme).
  - `ConnectionManager` tests against a scripted VM: hot restart, Sentinel answers, timeouts, version mismatch, disabled inspector.
  - A light platform test (`BasePlatformTestCase`) that the tool window, actions and services register.
  - `DemoServerIntegrationTest`, which spawns the Dart demo server and drives the real `VmServiceClient`. It covers list, schema, rows with search and sort, masked values, editing, the SQL write-confirmation path, `value.read` of the 2 MB blob, export, hot restart reconnect and stop. It's skipped when `dart` isn't on `PATH`.

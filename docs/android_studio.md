# Android Studio / IntelliJ plugin

The **Flutter DB Inspector** plugin adds a *Flutter DB* tool window to Android Studio and IntelliJ IDEA (2025.1 / build 251 and newer). It speaks the same [protocol](protocol.md) as the VS Code and DevTools clients. It never reads database files and has no database logic: every request goes to the app's `flutter_db_inspector` package through the Dart VM service.

Source: [`integrations/android-studio/flutter-db-inspector`](../integrations/android-studio/flutter-db-inspector).

## Install

In Android Studio or IntelliJ IDEA, open **Settings ▸ Plugins ▸ Marketplace**, search for **Flutter DB Inspector**, click **Install** and restart if asked. The plugin page is <https://plugins.jetbrains.com/plugin/34899-flutter-db-inspector>.

To install a build from source instead (or the `flutter-db-inspector-intellij-plugin` artifact from CI):

```bash
cd integrations/android-studio/flutter-db-inspector
./gradlew buildPlugin        # → build/distributions/flutter-db-inspector-<version>.zip
```

Then use **Settings ▸ Plugins ▸ ⚙ ▸ Install Plugin from Disk…**, pick the zip, and restart if asked.

The plugin depends only on `com.intellij.modules.platform`. It doesn't need the Flutter or Dart plugins.

## Set up with an AI assistant

Using Claude Code, Gemini, GitHub Copilot, Cursor or another coding agent? Open
your Flutter project in it and paste the prompt below. The agent finds the
databases your app uses, adds only the packages it needs, and puts the
initialization and registration code in the right places.

```text
Add Flutter DB Inspector (https://pub.dev/packages/flutter_db_inspector) to
this Flutter app so I can inspect its local data from DevTools, VS Code or
Android Studio. It must only run in debug builds.

1. FIND THE STORAGE
   Search pubspec.yaml and lib/ for every local storage the app uses:
   sqflite, sqflite_common_ffi, floor, drift, isar_community, objectbox,
   realm, sembast, hive_ce, shared_preferences, flutter_secure_storage,
   get_storage. For each one, find the file and variable where the app opens
   or creates the instance. Show me this list before changing anything.

2. ADD DEPENDENCIES (flutter pub add), only for what you found:
   - flutter_db_inspector_core
   - plus the matching connector for each storage:
     sqflite / sqflite_common_ffi / floor -> flutter_db_inspector_sqlite
     drift              -> flutter_db_inspector_drift
     isar_community     -> flutter_db_inspector_isar
     objectbox          -> flutter_db_inspector_objectbox
     realm              -> flutter_db_inspector_realm
     sembast            -> flutter_db_inspector_sembast
     hive_ce            -> flutter_db_inspector_hive
     shared_preferences -> flutter_db_inspector_shared_preferences
     flutter_secure_storage -> flutter_db_inspector_secure_storage
     get_storage        -> flutter_db_inspector_get_storage
   Use core + connectors, NOT the all-in-one flutter_db_inspector package: it
   pulls in every engine (the Isar/ObjectBox/Realm ones use dart:ffi and break
   Flutter web) and can clash with build_runner / drift_dev.
   If the app uses the original `isar` package (not isar_community) or classic
   `hive` 2.x (not hive_ce), do not add that connector; tell me instead.
   If pub cannot resolve, stop and show me the error. Never change the
   versions of my existing dependencies.

3. INITIALIZE ONCE in main(), in every entry point (main.dart, main_dev.dart,
   flavor mains), after WidgetsFlutterBinding.ensureInitialized() and before
   runApp():
     import 'package:flutter/foundation.dart';
     import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
     DbInspector.initialize(enabled: kDebugMode);

4. REGISTER EACH DATABASE right after the app opens it, in that same place
   (main, service locator / get_it setup, Riverpod or Bloc provider,
   repository init). Reuse the app's existing instance; never open a second
   connection. Wrap each call in `if (kDebugMode) { ... }`. Use a short,
   unique name per database. Import each connector as
   package:flutter_db_inspector_<name>/flutter_db_inspector_<name>.dart.
     sqflite / ffi: DbInspector.registerDatabase(name: 'app', adapter: SqliteAdapter(db));
     Floor:         SqliteAdapter(floorDb.database)
     Drift:         DriftAdapter(db)                 // the GeneratedDatabase instance
     Isar:          IsarAdapter(isar, schemas)       // same schema list given to Isar.open
     ObjectBox:     ObjectBoxAdapter(store, [ObjectBoxCollection<Task>(store.box<Task>(),
                      name: 'Task', toJson: (t) => {...}, fromJson: (j) => Task(...),
                      getId: (t) => t.id), ...])     // one per @Entity, built from its fields
     Realm:         RealmAdapter(realm)              // on the isolate that opened it
     Sembast:       SembastAdapter(db, stores: [...]) // store names used by StoreRef
     Hive:          HiveAdapter([box1, box2])        // or HiveAdapter.dynamic(() => [...])
                                                     // when boxes open at different times
     SharedPreferences: SharedPreferencesAdapter(prefs)
                    // or .async(SharedPreferencesAsync()) / .withCache(prefsWithCache),
                    // matching the API the app uses
     Secure storage: SecureStorageAdapter(storage)   // the app's own instance and options
     GetStorage:    GetStorageAdapter({'GetStorage': GetStorage(), 'cache': GetStorage('cache')})
                    // every container the app uses, after GetStorage.init

5. DO NOT change release behaviour, close or reopen databases, move existing
   database initialization, add network code, or edit unrelated code. Keep
   secure storage values masked (do not set revealValues).

6. VERIFY: run flutter pub get and flutter analyze (no new issues). Then tell
   me: run the app in debug, look for "Flutter DB Inspector enabled" in the
   IDE's Debug Console or DevTools' Logging view, and open the "flutter_db_inspector" tab in DevTools, the "Flutter DB" view
   in VS Code, or the "Flutter DB" tool window in Android Studio.

Finish with a short summary: files changed, databases registered
(name -> adapter), and anything you could not register and why.
```

Review the agent's changes before you commit them.

## Use

1. Set up the app as described in [getting_started.md](getting_started.md) (`DbInspector.initialize()` + `registerDatabase`).
2. Run or debug the app from a Flutter or Dart run configuration. The plugin finds the VM service URI in the run console and connects to the newest app. It disconnects when that process stops.
3. Open **View ▸ Tool Windows ▸ Flutter DB**, or **Tools ▸ Flutter DB Inspector ▸ Open Inspector**.

If the app was started from a terminal (`flutter run`, `dart run --enable-vm-service`), use **Tools ▸ Flutter DB Inspector ▸ Connect to VM Service URI…** and paste the `http://127.0.0.1:PORT/TOKEN=/` URI, a `ws://…/ws` URI or a DevTools link.

Without a device, run the demo server and connect to the URI it prints:

```bash
cd packages/flutter_db_inspector_sqlite
dart pub get
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
./gradlew verifyPlugin -PverifyIdes=IU-2026.2.3   # also download and check other IDE versions
./gradlew runIde                           # sandbox IDE with the plugin
```

- **Target platform**: by default the build compiles against a local IDE (`platformLocalPath` in `gradle.properties`, `/Applications/Android Studio.app`), which avoids a ~1 GB download. If that path doesn't exist, or you pass `-PplatformLocalPath=`, it downloads IntelliJ IDEA Community `platformVersion` (2025.1.3), as CI does.
- **Compatibility**: `since-build` is 251 and there's no `until-build`. The Kotlin API version is pinned to 2.1, the stdlib bundled with 2025.1. `verifyPlugin` checks the plugin against Android Studio (253) and IntelliJ IDEA CE 2025.1.3 (251) when they're installed.
- **Tests** (`src/test/kotlin`):
  - Unit tests for values, URIs and console discovery, protocol parsing, query store and exporter, and the web UI bridge (request dispatch, message shapes) and resource serving (paths, MIME types, theme).
  - `ConnectionManager` tests against a scripted VM: hot restart, Sentinel answers, timeouts, version mismatch, disabled inspector.
  - A light platform test (`BasePlatformTestCase`) that the tool window, actions and services register.
  - `DemoServerIntegrationTest`, which spawns the Dart demo server and drives the real `VmServiceClient`. It covers list, schema, rows with search and sort, masked values, editing, the SQL write-confirmation path, `value.read` of the 2 MB blob, export, hot restart reconnect and stop. It's skipped when `dart` isn't on `PATH`.

## Publishing

The plugin ID is `com.manishdevan.flutterdb` (vendor `manishdevan`), published on [JetBrains Marketplace](https://plugins.jetbrains.com/plugin/34899-flutter-db-inspector). Android Studio installs plugins from the same marketplace.

### First release (by hand)

Marketplace accepts updates through its API only after the plugin exists, so upload 1.0.0 on the website:

1. Build the zip against the since-build platform, so it runs on every IDE it claims (251+):

   ```bash
   ./gradlew -PplatformLocalPath= clean buildPlugin verifyPlugin
   ```

   `-PplatformLocalPath=` builds against IntelliJ IDEA Community `platformVersion` instead of the local Android Studio. The result is `build/distributions/flutter-db-inspector-<version>.zip`.
2. Sign in at <https://plugins.jetbrains.com> with a JetBrains Account and accept the developer agreement.
3. Open <https://plugins.jetbrains.com/plugin/add>, upload the zip, pick the **MIT** license, the **Tools Integration** (or **Database**) tag, and `https://github.com/developermanishdevan/flutter-local-db-inspector` as the source code URL.
4. JetBrains reviews new plugins by hand, which usually takes a few working days. You get an email when it is approved.

### Later releases

1. Create a Marketplace token: profile ▸ **My Tokens** ▸ **Generate Token**. Add it as the GitHub repository secret `PUBLISH_TOKEN`.
2. Bump `pluginVersion` in `gradle.properties` and add the version to `changeNotes` in `build.gradle.kts`.
3. Commit, then tag and push:

   ```bash
   git tag android-studio-v<version>
   git push origin android-studio-v<version>
   ```

   [`release-android-studio.yml`](../.github/workflows/release-android-studio.yml) checks that the tag matches `pluginVersion`, builds against IntelliJ IDEA Community 2025.1.3, publishes with `publishPlugin`, and attaches the zip to a GitHub release. Running it manually from the Actions tab only builds the zip, unless you tick *Publish*.

To publish from your machine instead: `PUBLISH_TOKEN=<token> ./gradlew -PplatformLocalPath= publishPlugin`.

### Signing (optional)

Marketplace signs every plugin itself, so this is not required. To also sign with your own certificate, generate one and add the three values as secrets (`CERTIFICATE_CHAIN`, `PRIVATE_KEY`, `PRIVATE_KEY_PASSWORD`, each the full PEM text). `signPlugin` is skipped when they are not set.

```bash
openssl genpkey -aes-256-cbc -algorithm RSA -out private_encrypted.pem -pkeyopt rsa_keygen_bits:4096
openssl rsa -in private_encrypted.pem -out private.pem
openssl req -key private.pem -new -x509 -days 3650 -out chain.crt
```

<p align="center"><img src="https://raw.githubusercontent.com/developermanishdevan/flutter-local-db-inspector/main/Imges/image.jpg" alt="Flutter DB Inspector" width="200"></p>

# Flutter DB Inspector for VS Code

Inspect, query and edit the local databases of your **running** Flutter app from VS Code. You don't need to find the database file on the device, copy it out, or install a separate SQLite browser.

| Data model | Engines | Shown as |
|---|---|---|
| Relational | SQLite, sqflite, Drift, Floor, sqflite_common_ffi | Tables, views, indexes, triggers · rows · SQL console |
| Object / document | Isar, ObjectBox, Realm, Sembast | Collections · objects |
| Key-value | Hive, SharedPreferences, Secure Storage, GetStorage | Boxes · entries |

The extension never reads database files. It talks to your app through the Dart VM service, and the app's `flutter_db_inspector` package executes every request. It uses the same protocol as the DevTools extension and the Android Studio plugin.

## Install

Install **Flutter DB Inspector** from the Extensions view (search `developer-manishdevan.flutter-db-inspector`), or run:

```bash
code --install-extension developer-manishdevan.flutter-db-inspector
```

It is also on [Open VSX](https://open-vsx.org/extension/developer-manishdevan/flutter-db-inspector) for Cursor, VSCodium and Windsurf.

## Setup

1. Add the one package to the app (every connector is included):

   ```yaml
   dependencies:
     flutter_db_inspector: ^1.0.0
   ```

2. Enable the inspector with your databases:

   ```dart
   void main() async {
     WidgetsFlutterBinding.ensureInitialized();
     final db = await openDatabase('app.db');

     DbInspector.initialize(
       enabled: kDebugMode,
       databases: [
         InspectorDatabase(name: 'app_database', adapter: SqliteAdapter(db)),
       ],
     );

     runApp(const MyApp());
   }
   ```

3. Run the app in debug mode (F5). The **Flutter DB** view connects automatically.

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

## Features

- **Database tree**: databases grouped by tables, views, collections or boxes, with row counts. Indexes and triggers are listed too.
- **Table search**: **Filter Tables…** (filter icon on the view) narrows the tree as you type and highlights matches; **Go to Table…** (search icon, Ctrl/Cmd+Alt+T) jumps to any table, collection or box in any database.
- **Data grid**: 
  - Server-side paging (at most 100 rows per page), search, filters and sorting.
  - Resizable columns and keyboard navigation.
  - Inline editing (Enter/F2), add, duplicate and delete records, and copy a cell or row as JSON or CSV.
  - **Query** button (SQL databases): opens the SQL console with `SELECT * FROM <table> LIMIT 50;` to start from. Nothing runs until you press Run, and text you already typed is kept.
- **Value inspector**:
  - JSON shown pretty or raw.
  - Large text loaded on demand.
  - BLOBs shown as a hex preview and saved to a file in chunks.
- **Schema**: columns, types, keys, foreign keys, indexes, triggers and the DDL.
- **SQL console** (SQL databases): run statements with Ctrl/Cmd+Enter and see timing and row counts. Statements that modify data need confirmation.
- **Run SQL files**: run the current `.sql` file or selection against the app with Ctrl/Cmd+Enter.
- **Query history and saved queries**: stored in VS Code, never in your app.
- **Statistics**: database size, record counts and largest tables.
- **Export**: a table or a whole database to JSON, CSV or SQL. Exports are streamed in pages, and masked columns are exported as `null`.
- **Hot restart aware**: the extension reconnects automatically and reloads open views.

Which operations are available depends on what each database supports. For example, Hive has no SQL console and views are read-only.

## Safety

- The inspector is disabled in release builds and never opens a network port.
- Deleting rows, clearing tables and SQL that writes data always ask for confirmation.
- Columns the app marks as sensitive (`sensitiveColumns`) are masked inside the app and never sent to VS Code. Secure Storage values are masked by default.
- `DbInspector.initialize(readOnly: true)` disables all writes.

## Commands

| Command | Description |
|---|---|
| Flutter DB: Open Inspector | Focus the Flutter DB view |
| Flutter DB: Go to Table… | Search every table, collection and box by name and open it |
| Flutter DB: Filter Tables… | Filter the database tree by name (clear with the filled filter icon) |
| Flutter DB: Connect to VM Service URI… | Attach to an app started outside VS Code (`flutter run`) |
| Flutter DB: Refresh | Reload databases and open views |
| Flutter DB: Run Query | Run the current SQL file or selection (Ctrl/Cmd+Enter) |
| Flutter DB: Open SQL Console | Open a SQL console for a database |
| Flutter DB: Export Database | Export every table or collection |
| Flutter DB: Show Statistics | Show the statistics view |

### Keyboard shortcuts in the data grid

| Keys | Action |
|---|---|
| Arrows, Home/End, PageUp/PageDown | Move between cells |
| Enter / F2 | Edit cell (Esc cancels) |
| Delete | Delete row (asks first) |
| Ctrl/Cmd+C, Ctrl/Cmd+Shift+C | Copy cell, copy row as JSON |
| Ctrl/Cmd+F | Search |
| Ctrl/Cmd+R / F5 | Refresh |

## Settings

| Setting | Default | |
|---|---|---|
| `flutterDbInspector.autoConnect` | `true` | Connect to Dart/Flutter debug sessions automatically |
| `flutterDbInspector.defaultPageSize` | `50` | Rows per page (25, 50 or 100) |
| `flutterDbInspector.requestTimeoutMs` | `30000` | How long to wait for the app to answer |
| `flutterDbInspector.historyLimit` | `100` | Queries kept in history (0 disables history) |
| `flutterDbInspector.confirmCellEdits` | `false` | Ask before saving an edited cell |

## Troubleshooting

- **"Waiting for the app to call DbInspector.initialize()"**: the app is running, but the inspector isn't enabled. Check `DbInspector.initialize()` in `main` and make sure you're running a debug build.
- **No databases**: call `DbInspector.registerDatabase` after opening the database. The view updates as soon as you do.
- **App started from a terminal**: use *Flutter DB: Connect to VM Service URI…* and paste the `A Dart VM Service … is available at:` URI.
- **Logs**: *Output → Flutter DB Inspector*.

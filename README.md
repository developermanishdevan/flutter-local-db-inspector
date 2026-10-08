<p align="center"><img src="Imges/image.jpg" alt="Flutter DB Inspector" width="200"></p>

# Flutter DB Inspector

[![VS Code Marketplace](https://img.shields.io/visual-studio-marketplace/v/developer-manishdevan.flutter-db-inspector?label=VS%20Code%20Marketplace&logo=visualstudiocode)](https://marketplace.visualstudio.com/items?itemName=developer-manishdevan.flutter-db-inspector)
[![JetBrains Marketplace](https://img.shields.io/jetbrains/plugin/v/34899?label=JetBrains%20Marketplace&logo=jetbrains)](https://plugins.jetbrains.com/plugin/34899-flutter-db-inspector)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> The database inspector built specifically for Flutter developers.

Inspect, query, edit and export your Flutter app's local storage **while the app runs**. No need to find database files on a device, copy them off, or open them in a separate SQLite browser.

```
Run Flutter app → Open Flutter DB Inspector → Database → Table → Rows → Search / Filter / Edit / Query
```

## One inspector, three data models

The inspector doesn't assume everything is a SQL table. Each adapter reports its **data model** and its **capabilities**, and every client adapts to those:

| Data model | Engines | Browsed as | Query |
|---|---|---|---|
| **relational** | SQLite, sqflite, sqflite_common_ffi, Floor, **Drift** | tables & views · rows | SQL console |
| **document** | **Isar**, **ObjectBox**, **Realm**, **Sembast** | collections · objects | filter / sort / search |
| **keyValue** | **Hive**, **SharedPreferences**, **Secure Storage**, GetStorage | boxes · entries | filter / sort / search |

## Install the IDE tools

| IDE | Install |
|---|---|
| **VS Code** | [Flutter DB Inspector on the Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=developer-manishdevan.flutter-db-inspector), or `code --install-extension developer-manishdevan.flutter-db-inspector` |
| **Android Studio / IntelliJ IDEA** (2025.1+) | [Flutter DB Inspector on JetBrains Marketplace](https://plugins.jetbrains.com/plugin/34899-flutter-db-inspector), or **Settings ▸ Plugins ▸ Marketplace**, search *Flutter DB Inspector* |
| **DevTools** | Nothing to install: the extension ships inside the `flutter_db_inspector` package |

## Quick start

Add **one** package; every connector is included:

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
```

> Until the packages are published to pub.dev, use this GitHub repository directly. That one entry is still all you need:
>
> ```yaml
> dependencies:
>   flutter_db_inspector:
>     git:
>       url: https://github.com/developermanishdevan/flutter-local-db-inspector.git
>       path: packages/flutter_db_inspector
> ```
>
> To build the VS Code and Android Studio plugins from source, see [docs/vscode.md](docs/vscode.md) and [docs/android_studio.md](docs/android_studio.md).

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_db_inspector/flutter_db_inspector.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openDatabase('app.db');
  final cache = await Hive.openBox('cache');

  DbInspector.initialize(
    enabled: kDebugMode,
    databases: [
      InspectorDatabase(name: 'app_database', adapter: SqliteAdapter(db)),
      InspectorDatabase(name: 'cache', adapter: HiveAdapter([cache])),
    ],
  );

  runApp(const MyApp());
}
```

Databases opened later can still be added with `DbInspector.registerDatabase(name: ..., adapter: ...)`.

Run the app in debug mode and open the **flutter_db_inspector** tab in DevTools, the **Flutter DB** view in VS Code, or the **Flutter DB** tool window in Android Studio / IntelliJ. See [docs/getting_started.md](docs/getting_started.md).

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

## Packages

| Package | Purpose |
|---|---|
| [`flutter_db_inspector`](packages/flutter_db_inspector) | **The one package apps add.** Re-exports the runtime and every connector below, and ships the DevTools extension |
| [`flutter_db_inspector_core`](packages/flutter_db_inspector_core) | Runtime: `DbInspector`, registry, router, VM service extension, generic document and key-value engines |
| [`flutter_db_inspector_protocol`](packages/flutter_db_inspector_protocol) | Wire protocol shared by the runtime and every client |
| [`flutter_db_inspector_client`](packages/flutter_db_inspector_client) | Pure Dart client (VM service connection, hot-restart handling, typed protocol calls) |
| [`flutter_db_inspector_devtools`](packages/flutter_db_inspector_devtools) | DevTools extension source (Flutter web); built into `flutter_db_inspector/extension/devtools` |
| [`flutter_db_inspector_sqlite`](packages/flutter_db_inspector_sqlite) | SQLite / sqflite / FFI / Floor |
| [`flutter_db_inspector_drift`](packages/flutter_db_inspector_drift) | Drift (edits refresh the app's `watch()` streams) |
| [`flutter_db_inspector_isar`](packages/flutter_db_inspector_isar) | Isar (`isar_community`) |
| [`flutter_db_inspector_objectbox`](packages/flutter_db_inspector_objectbox) | ObjectBox |
| [`flutter_db_inspector_realm`](packages/flutter_db_inspector_realm) | Realm |
| [`flutter_db_inspector_sembast`](packages/flutter_db_inspector_sembast) | Sembast |
| [`flutter_db_inspector_hive`](packages/flutter_db_inspector_hive) | Hive (`hive_ce`) |
| [`flutter_db_inspector_shared_preferences`](packages/flutter_db_inspector_shared_preferences) | SharedPreferences, SharedPreferencesAsync, SharedPreferencesWithCache |
| [`flutter_db_inspector_secure_storage`](packages/flutter_db_inspector_secure_storage) | flutter_secure_storage (values masked by default) |
| [`flutter_db_inspector_get_storage`](packages/flutter_db_inspector_get_storage) | GetStorage |

Connector packages are included by `flutter_db_inspector`. Size-sensitive apps can depend on `flutter_db_inspector_core` plus only the connectors they use. The all-in-one package also brings in the SharedPreferences, Secure Storage and GetStorage plugins and Drift's bundled SQLite, even when your app doesn't use them.

## Clients

| Client | Status |
|---|---|
| [VS Code extension](integrations/vscode/flutter-db-inspector) · [Marketplace](https://marketplace.visualstudio.com/items?itemName=developer-manishdevan.flutter-db-inspector) | ✅ 1.0: tree, data grid, editing, schema, SQL console, history, statistics, export |
| [DevTools extension](docs/devtools.md) | ✅ 1.0: ships inside `flutter_db_inspector`; tree, data grid, editing, schema, SQL console with history, statistics |
| [Android Studio / IntelliJ plugin](integrations/android-studio/flutter-db-inspector) · [Marketplace](https://plugins.jetbrains.com/plugin/34899-flutter-db-inspector) | ✅ 1.0: *Flutter DB* tool window; run-console discovery, tree, data grid, editing, schema, SQL console with history, statistics, export ([docs](docs/android_studio.md)) |

## Architecture in one picture

```
Flutter app ── flutter_db_inspector ── adapters (SQLite, Drift, Isar, Hive, …)
                     │
        ext.flutter_db_inspector.request   (Dart VM service extension, JSON protocol v1)
                     │
     VS Code  ·  DevTools  ·  Android Studio     (clients never touch database files)
```

Details: [docs/architecture.md](docs/architecture.md) · [docs/protocol.md](docs/protocol.md) · [docs/security.md](docs/security.md)

## Development

```bash
tool/check.sh           # format + analyze + test everything, including the VS Code extension
tool/check.sh --all     # also the Isar / ObjectBox / Realm native suites
```

Try the extension without a device: run `dart run --enable-vm-service example/inspector_server.dart` in `packages/flutter_db_inspector_sqlite`, then use **Flutter DB: Connect to VM Service URI…** in VS Code. Or run [`examples/sqlite_example`](examples/sqlite_example) on any device.

> **Security:** this is a development tool. It is disabled in release builds, never opens a network port, and supports read-only mode and masking. See [docs/security.md](docs/security.md).

License: [MIT](LICENSE)

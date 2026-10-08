<p align="center"><img src="Imges/image.jpg" alt="Flutter DB Inspector" width="200"></p>

# Flutter DB Inspector

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
> To build the VS Code and Android Studio installers, see [docs/vscode.md](docs/vscode.md) and [docs/android_studio.md](docs/android_studio.md).

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
| [VS Code extension](integrations/vscode/flutter-db-inspector) | ✅ v0.1: tree, data grid, editing, schema, SQL console, history, statistics, export |
| [DevTools extension](docs/devtools.md) | ✅ v0.1: ships inside `flutter_db_inspector`; tree, data grid, editing, schema, SQL console with history, statistics |
| [Android Studio / IntelliJ plugin](integrations/android-studio/flutter-db-inspector) | ✅ v0.1: *Flutter DB* tool window; run-console discovery, tree, data grid, editing, schema, SQL console with history, statistics, export ([docs](docs/android_studio.md)) |

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

<p align="center"><img src="https://raw.githubusercontent.com/developermanishdevan/flutter-local-db-inspector/main/Imges/image.jpg" alt="Flutter DB Inspector" width="200"></p>

# flutter_db_inspector

Inspect, query, edit and export your Flutter app's local storage **while the
app runs**, from DevTools, VS Code or Android Studio. No need to find database
files on a device, copy them off, or open them in a separate SQLite browser.

```
Run Flutter app → Open Flutter DB Inspector → Database → Table → Rows → Search / Filter / Edit / Query
```

This package is the runtime, the wire protocol and the **DevTools
extension**. It is pure Dart with no database dependencies. Add it plus one
connector package per storage your app uses.

## Supported storage

| Data model | Engines | Browsed as | Query |
|---|---|---|---|
| **relational** | SQLite, sqflite, sqflite_common_ffi, Floor, Drift | tables & views · rows | SQL console |
| **document** | Isar, ObjectBox, Realm, Sembast | collections · objects | filter / sort / search |
| **keyValue** | Hive, SharedPreferences, Secure Storage, GetStorage | boxes · entries | filter / sort / search |

## Install

```yaml
dependencies:
  flutter_db_inspector: ^2.0.0
  flutter_db_inspector_sqlite: ^2.0.0   # one connector per storage you use
  flutter_db_inspector_hive: ^2.0.0
```

| Storage | Connector package | Adapter |
|---|---|---|
| sqflite / sqflite_common_ffi / Floor | `flutter_db_inspector_sqlite` | `SqliteAdapter(db)` |
| Drift | `flutter_db_inspector_drift` | `DriftAdapter(db)` |
| Isar (`isar_community`) | `flutter_db_inspector_isar` | `IsarAdapter(isar, schemas)` |
| ObjectBox | `flutter_db_inspector_objectbox` | `ObjectBoxAdapter(store, collections)` |
| Realm | `flutter_db_inspector_realm` | `RealmAdapter(realm)` |
| Sembast | `flutter_db_inspector_sembast` | `SembastAdapter(db)` |
| Hive (`hive_ce`) | `flutter_db_inspector_hive` | `HiveAdapter(boxes)` |
| SharedPreferences | `flutter_db_inspector_shared_preferences` | `SharedPreferencesAdapter(prefs)` |
| flutter_secure_storage | `flutter_db_inspector_secure_storage` | `SecureStorageAdapter(storage)` |
| GetStorage | `flutter_db_inspector_get_storage` | `GetStorageAdapter(containers)` |

## Set up

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_db_inspector/flutter_db_inspector.dart';
import 'package:flutter_db_inspector_hive/flutter_db_inspector_hive.dart';
import 'package:flutter_db_inspector_sqlite/flutter_db_inspector_sqlite.dart';

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

Databases opened later can still be added with
`DbInspector.registerDatabase(name: ..., adapter: ...)`.

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
   - flutter_db_inspector (runtime, protocol and the DevTools tab)
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
   Add only the connectors for storage the app actually uses; each one pulls
   in its database's own dependencies.
   If the app uses the original `isar` package (not isar_community) or classic
   `hive` 2.x (not hive_ce), do not add that connector; tell me instead.
   If pub cannot resolve, stop and show me the error. Never change the
   versions of my existing dependencies.

3. INITIALIZE ONCE in main(), in every entry point (main.dart, main_dev.dart,
   flavor mains), after WidgetsFlutterBinding.ensureInitialized() and before
   runApp():
     import 'package:flutter/foundation.dart';
     import 'package:flutter_db_inspector/flutter_db_inspector.dart';
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

## Open the inspector

Run the app in debug mode, then use any of:

- **DevTools:** open the **flutter_db_inspector** tab. The extension ships in
  this package, so there is nothing else to install. Enable it the first time
  DevTools asks.
- **VS Code:** the **Flutter DB** view ([install the extension](https://marketplace.visualstudio.com/items?itemName=developer-manishdevan.flutter-db-inspector)).
- **Android Studio / IntelliJ:** the **Flutter DB** tool window ([install the plugin](https://plugins.jetbrains.com/plugin/34899-flutter-db-inspector)).

## Features

- Database tree, data grid with filter, sort and search
- Insert, update and delete rows; clear tables
- Schema view, SQL console with history, statistics
- Export (VS Code and Android Studio)

## Security

This is a development tool:

- Disabled in release builds; it never opens a network port. Clients talk to
  the app only through the Dart VM service.
- `DbInspector.initialize(readOnly: true)` blocks every write.
- `sensitiveColumns` masks values; Secure Storage values are masked by default.

## Upgrading from 1.x

In 1.x this package re-exported every connector. In 2.0.0 the connectors are
opt-in, and `flutter_db_inspector_core` and `flutter_db_inspector_protocol`
are merged into this package. See the
[CHANGELOG](https://github.com/developermanishdevan/flutter-local-db-inspector/blob/main/packages/flutter_db_inspector/CHANGELOG.md)
for the migration steps.

## More

- [Getting started](https://github.com/developermanishdevan/flutter-local-db-inspector/blob/main/docs/getting_started.md)
- [DevTools extension](https://github.com/developermanishdevan/flutter-local-db-inspector/blob/main/docs/devtools.md)
- [Security](https://github.com/developermanishdevan/flutter-local-db-inspector/blob/main/docs/security.md)
- [Report an issue](https://github.com/developermanishdevan/flutter-local-db-inspector/issues)

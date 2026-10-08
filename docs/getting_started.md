# Getting started

## 1. Add the package

One package includes the runtime and every connector:

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
```

Until the packages are on pub.dev, depend on the GitHub repository. You still
need only this one entry; the connectors are resolved through it:

```yaml
dependencies:
  flutter_db_inspector:
    git:
      url: https://github.com/developermanishdevan/flutter-local-db-inspector.git
      path: packages/flutter_db_inspector
```

With a local clone, use `path: <path-to-repo>/packages/flutter_db_inspector` instead.

## 2. Initialize with your databases

```dart
import 'package:flutter_db_inspector/flutter_db_inspector.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = await openDatabase('app.db');
  final box = await Hive.openBox('cache');

  DbInspector.initialize(
    enabled: kDebugMode,                       // the default; never enabled in release
    sensitiveColumns: {'users.password', '*.token'},
    databases: [
      InspectorDatabase(name: 'app_database', adapter: SqliteAdapter(db)),
      InspectorDatabase(name: 'cache', adapter: HiveAdapter([box])),
    ],
  );

  runApp(const MyApp());
}
```

`InspectorDatabase` takes `name`, `adapter` and optional `readOnly: true`.
A database opened later (after login, per user, …) can be added any time with
`DbInspector.registerDatabase(name: ..., adapter: ...)`.

| Engine | Registration |
|---|---|
| sqflite / sqflite_common_ffi | `SqliteAdapter(database)` |
| Floor | `SqliteAdapter(floorDatabase.database)` |
| Drift | `DriftAdapter(appDatabase)` |
| Isar | `IsarAdapter(isar, [UserSchema, PostSchema])` |
| ObjectBox | `ObjectBoxAdapter(store, [ObjectBoxCollection<User>(store.box<User>(), name: 'User', toJson: …, fromJson: …, getId: …)])` |
| Realm | `RealmAdapter(realm)` |
| Sembast | `SembastAdapter(db)` |
| Hive | `HiveAdapter([box1, box2])` or `HiveAdapter.dynamic(() => openBoxes)` |
| SharedPreferences | `SharedPreferencesAdapter(prefs)` / `.async(asyncPrefs)` |
| Secure Storage | `SecureStorageAdapter(const FlutterSecureStorage())` |

Connected clients update as soon as a database is registered.

## 3. Open the inspector

**VS Code:** install the *Flutter DB Inspector* extension and run the app with F5. The **Flutter DB** view in the activity bar connects automatically. If the app was started from a terminal (`flutter run`), use **Flutter DB: Connect to VM Service URI…** and paste the URI that `flutter run` prints.

After a hot restart, the inspector reconnects and reloads by itself.

## 4. Try it without your own app

```bash
cd examples/sqlite_example && flutter run          # SQLite + Hive + SharedPreferences demo app
# or, without any device:
cd packages/flutter_db_inspector_sqlite
dart run --enable-vm-service example/inspector_server.dart
```

The demo database has 1,000 users, 5,000 products, 10,000 orders and a table of edge-case values: JSON, Unicode and emoji, 64-bit integers, a 2 MB BLOB and long text.

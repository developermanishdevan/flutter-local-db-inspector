# Database adapters

| Package | Engine | Data model | Native filtering | Notes |
|---|---|---|---|---|
| `flutter_db_inspector_sqlite` | SQLite, sqflite, sqflite_common_ffi, Floor | relational | SQL | SQL console; views read-only; WITHOUT ROWID tables use the primary key |
| `flutter_db_inspector_drift` | Drift (Moor users: migrate to Drift) | relational | SQL | Edits notify Drift so `watch()` streams update |
| `flutter_db_inspector_isar` | Isar (`isar_community`) | document | Isar queries for strings, ints, bools and nulls | Pass the same schemas you give to `Isar.open` |
| `flutter_db_inspector_objectbox` | ObjectBox | document | in-memory, bounded | Typed binding per entity (`toJson`, `fromJson`, `getId`) |
| `flutter_db_inspector_realm` | Realm (`realm` / `realm_dart` 20.x) | document | RQL | Realm SDKs were deprecated by MongoDB in Sept 2024 |
| `flutter_db_inspector_sembast` | Sembast | document | sembast `Finder` | Non-map records shown as `_value` |
| `flutter_db_inspector_hive` | Hive (`hive_ce`) | keyValue | in-memory | Box and LazyBox; custom objects shown through `toJson()` |
| `flutter_db_inspector_shared_preferences` | SharedPreferences (+Async, WithCache) | keyValue | in-memory | Edits keep the stored type |
| `flutter_db_inspector_secure_storage` | flutter_secure_storage | keyValue | in-memory | Values masked unless `revealValues: true` |
| `flutter_db_inspector_get_storage` | GetStorage | keyValue | in-memory | |

Each package's README describes installation, registration and limitations.

## Writing an adapter

Choose the engine family and implement its small binding interface:

```dart
// Key-value: Hive-like stores, preferences, MMKV, ...
final class MyStore extends KeyValueStore { … }
DbInspector.registerDatabase(
  name: 'prefs',
  adapter: KeyValueAdapter(type: 'my_store', stores: () => [MyStore()]),
);

// Document / object stores
final class MyCollection extends DocumentCollection { … }
DbInspector.registerDatabase(
  name: 'objects',
  adapter: DocumentAdapter(type: 'my_db', collections: () => [...]),
);

// Any SQLite library
final class MyExecutor implements SqliteExecutor { … }
DbInspector.registerDatabase(name: 'sql', adapter: SqliteAdapter.executor(MyExecutor()));
```

For anything else, extend `DbAdapter` directly. Override only the operations you support, and list them in `capabilities`.

Rules:
- Return raw Dart values. The runtime handles encoding, masking and size limits.
- Throw `InspectorException` with a standard error code. Other exceptions become `QUERY_FAILED`.
- Never read unbounded data. Honour `RowsQuery.pageSize`, `previewBytes` and `searchExcludedColumns`.
- Test through `InspectorRouter.handleRaw` with JSON, the same way clients call it. See any adapter's `test/` folder.

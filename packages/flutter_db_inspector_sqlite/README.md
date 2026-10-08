# flutter_db_inspector_sqlite

SQLite adapter for [Flutter DB Inspector](https://pub.dev/packages/flutter_db_inspector).
Browse tables and views, filter/sort/search rows, edit data and run SQL
against your app's SQLite database while it runs.

Works with `sqflite`, `sqflite_common_ffi`, Floor and any other SQLite library.
It also powers the Drift adapter.

## Install

Included in `flutter_db_inspector`. To use it on its own:

```yaml
dependencies:
  flutter_db_inspector_core: ^1.0.0
  flutter_db_inspector_sqlite: ^1.0.0
```

## Register

```dart
// sqflite / sqflite_common_ffi
DbInspector.registerDatabase(name: 'app', adapter: SqliteAdapter(db));

// Floor
DbInspector.registerDatabase(
  name: 'app',
  adapter: SqliteAdapter(floorDb.database),
);
```

Any other SQLite library: implement `SqliteExecutor` (`select`, `modify`,
`insert`, `execute`, `path`) and pass it to `SqliteAdapter.executor(...)`.

The adapter uses your app's own connection; it never opens a second handle on
the database file. Large values are truncated inside SQLite, so huge blobs
never reach Dart memory while browsing.

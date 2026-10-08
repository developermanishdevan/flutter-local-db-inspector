# Changelog

## 1.0.0

- One shared data UI: the grid, value inspector, row form, SQL console and statistics are the same in VS Code, Android Studio and DevTools.
- **Query** button in the table toolbar (SQL databases): opens the SQL console with `SELECT * FROM <table> LIMIT 50;` as a starting point. It never runs by itself and never replaces a query you typed.
- Wording follows the storage engine: rows / objects / entries, and "fields" and "Structure" for non-relational data.
- Activates only in workspaces that contain a `pubspec.yaml` (or when a Dart debug session starts).
- The VM service auth token is no longer written to the output log.
- Requires `flutter_db_inspector` 1.0.0 in the app.

## 0.1.0

- Connects automatically to Flutter/Dart debug sessions (or any VM service URI) and reconnects after hot restart.
- Database tree for relational (SQLite, Drift), document (Isar, ObjectBox, Realm, Sembast) and key-value (Hive, SharedPreferences, Secure Storage, GetStorage) storage.
- Data grid: paging, search, filters, sorting, column resizing, inline editing, value inspector (JSON pretty/raw, large text, blobs), copy cell/row as JSON/CSV, add/duplicate/delete records.
- Schema view, SQL console with write confirmation, query history and saved queries, statistics, export to JSON/CSV/SQL.

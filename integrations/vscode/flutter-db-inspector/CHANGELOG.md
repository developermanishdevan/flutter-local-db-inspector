# Changelog

## 2.0.0

- **Saved queries are kept per app.** Each saved query belongs to the connected app's Dart package name (the `name:` in its `pubspec.yaml`, read from the running app; no code change needed). They are stored in VS Code's global state, so they stay across workspaces and restarts until you delete them. The Queries view shows a **Saved · <app>** group per app: the connected app's first and expanded, other apps' still listed.
- Saving under an existing name replaces that query instead of adding a duplicate. Saving asks for a name for the current app and confirms when done.
- Saved queries have inline **Run Again** and **Delete** buttons; deleting asks for confirmation.
- Saved queries from 1.x (kept per workspace) move to the first app you connect to.
- Works with `flutter_db_inspector` 2.0.0: the runtime, protocol and DevTools extension are one package, and connectors are added per database.

## 1.0.3

- Table view: new **Tables** button next to the table name. It opens a search box over the database's other tables, views, collections and boxes (with row counts); pick one to open it in a new tab. The current table stays open, and a table that is already open is brought to the front instead of opened twice.

## 1.0.2

- README: new **Set up with an AI assistant** section with a ready-to-paste prompt for Claude Code, Gemini, Copilot or Cursor. The agent finds the app's databases, adds only the needed packages, and inserts the initialization and registration code in the right places.
- Version aligned with the Android Studio plugin.

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

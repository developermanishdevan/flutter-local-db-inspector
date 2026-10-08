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

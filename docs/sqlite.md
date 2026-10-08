# SQLite, sqflite and Floor

```dart
final db = await openDatabase('app.db');                    // sqflite
DbInspector.registerDatabase(name: 'app', adapter: SqliteAdapter(db));

DbInspector.registerDatabase(name: 'app', adapter: SqliteAdapter(floorDb.database)); // Floor
```

What it supports:
- Tables, views, indexes (including automatic ones), triggers, foreign keys, generated columns, `WITHOUT ROWID` tables.
- Paging, filters, search across text-like columns, sorting with a stable tie-breaker, row counts.
- Insert, update, delete and clear. Views are read-only.
- SQL console:
  - Reads are wrapped as `SELECT * FROM (<sql>) LIMIT n`.
  - Writes need confirmation.
  - Multiple statements per request are rejected.
- Large values are truncated inside SQLite (`substr`), so a 50 MB BLOB never gets loaded just to render a grid. `value.read` streams it in 1 MB chunks.
- A locked database returns `DATABASE_BUSY`, never a crash.
- Declared types are mapped as follows: `BOOL…` → boolean, `DATE/TIME…` → dateTime, `JSON` → json, then the usual SQLite affinity rules.

Timeouts: SQLite can't abort a running statement from Dart. After `QUERY_TIMEOUT` the statement may still finish in the background.

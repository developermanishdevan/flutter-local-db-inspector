# flutter_db_inspector_drift

[Drift](https://drift.simonbinder.eu) adapter for Flutter DB Inspector. Browse
tables, filter/sort/search rows, edit data and run SQL against your app's Drift
database while it runs.

It reuses the SQLite engine from `flutter_db_inspector_sqlite`, but every
statement goes through **your Drift database's own connection** — the
inspector never opens a second handle on the file.

## Install

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
  flutter_db_inspector_drift: ^1.0.0
```

## Register

```dart
import 'package:flutter_db_inspector/flutter_db_inspector.dart';
import 'package:flutter_db_inspector_drift/flutter_db_inspector_drift.dart';

final db = AppDatabase(); // your GeneratedDatabase subclass
DbInspector.registerDatabase(name: 'app', adapter: DriftAdapter(db));
```

`database.info` additionally reports the Drift `schemaVersion` and the
generated table classes (`driftTables`). The adapter never closes your
database.

## Stream notification

Edits made from the inspector refresh your `watch()` streams immediately:

- **Row edits** (insert, update, delete, clear table) notify only the edited
  table.
- **SQL console writes** can touch any table, so they notify every table in
  `allTables` (conservative, but always correct).

Changes to tables Drift does not know about (not in `allTables`) are applied
but cannot trigger streams.

## Moor

Moor is Drift's former name and is not supported directly. Migrate to Drift
first (the Drift documentation has a migration guide), then register the database with `DriftAdapter`.

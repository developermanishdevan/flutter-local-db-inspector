# Drift

```dart
DbInspector.registerDatabase(name: 'app', adapter: DriftAdapter(appDatabase));
```

The Drift adapter reuses the SQLite engine but runs every statement through Drift (`customSelect`, `customUpdate`, `customInsert`, `customStatement`). Edits made from the inspector therefore notify Drift's stream queries, and your UI updates immediately. Row edits notify only the table that was edited. SQL console writes notify every table, to be safe.

The metadata includes `schemaVersion` and the mapping from SQL table names to the generated Dart classes.

Moor is Drift's former name. Projects still on `moor` should migrate to `drift` to use this adapter.

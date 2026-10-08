/// SQLite adapter for Flutter DB Inspector.
///
/// ```dart
/// final db = await openDatabase('app.db'); // sqflite
/// DbInspector.registerDatabase(name: 'app', adapter: SqliteAdapter(db));
/// ```
library;

export 'src/sql_classifier.dart';
export 'src/sqlite_adapter.dart';
export 'src/sqlite_executor.dart';

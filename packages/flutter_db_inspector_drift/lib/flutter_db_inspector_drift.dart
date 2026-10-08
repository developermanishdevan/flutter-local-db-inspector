/// Drift adapter for Flutter DB Inspector.
///
/// ```dart
/// final db = AppDatabase(); // your GeneratedDatabase subclass
/// DbInspector.registerDatabase(name: 'app', adapter: DriftAdapter(db));
/// ```
library;

export 'src/drift_adapter.dart';
export 'src/drift_executor.dart';

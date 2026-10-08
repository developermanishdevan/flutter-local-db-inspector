/// Isar (`isar_community`) adapter for Flutter DB Inspector.
///
/// ```dart
/// DbInspector.registerDatabase(
///   name: 'isar',
///   adapter: IsarAdapter(isar, [UserSchema, NoteSchema]),
/// );
/// ```
library;

export 'src/isar_adapter.dart';
export 'src/isar_collection_binding.dart';
export 'src/isar_values.dart';

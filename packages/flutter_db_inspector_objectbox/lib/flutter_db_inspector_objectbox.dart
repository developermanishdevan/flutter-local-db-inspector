/// ObjectBox adapter for Flutter DB Inspector.
///
/// ```dart
/// DbInspector.registerDatabase(
///   name: 'objectbox',
///   adapter: ObjectBoxAdapter(store, [
///     ObjectBoxCollection<Task>(store.box<Task>(), name: 'Task', ...),
///   ]),
/// );
/// ```
library;

export 'src/objectbox_adapter.dart';
export 'src/objectbox_collection.dart';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:objectbox/objectbox.dart';

/// Inspects an ObjectBox [Store] through typed box bindings
/// (usually [ObjectBoxCollection]s).
///
/// ```dart
/// DbInspector.registerDatabase(
///   name: 'objectbox',
///   adapter: ObjectBoxAdapter(store, [
///     ObjectBoxCollection<Task>(store.box<Task>(), name: 'Task', ...),
///   ]),
/// );
/// ```
class ObjectBoxAdapter extends DocumentAdapter {
  ObjectBoxAdapter(
    this.store,
    List<DocumentCollection> collections, {
    super.maxScanDocuments,
  }) : super(
          type: 'objectbox',
          engine: 'objectbox',
          collections: () => collections,
        );

  final Store store;

  @override
  Future<DatabaseMetadata> getMetadata() async {
    final base = await super.getMetadata();
    return DatabaseMetadata(
      engine: base.engine,
      engineVersion: Store.databaseVersion(),
      path: store.directoryPath,
      extra: base.extra,
    );
  }
}

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:isar_community/isar.dart';

import 'isar_collection_binding.dart';

/// Inspects an [Isar] instance (`isar_community`).
///
/// Isar has no public API listing the collections of an open instance, so
/// pass the same schemas given to `Isar.open`:
///
/// ```dart
/// final isar = await Isar.open([UserSchema, NoteSchema], directory: dir);
/// DbInspector.registerDatabase(
///   name: 'isar',
///   adapter: IsarAdapter(isar, [UserSchema, NoteSchema]),
/// );
/// ```
class IsarAdapter extends DocumentAdapter {
  IsarAdapter(
    this.isar,
    List<CollectionSchema<Object?>> schemas, {
    super.maxScanDocuments,
  }) : super(
          type: 'isar',
          engine: 'isar_community',
          engineVersion: Isar.version,
          collections: _bindings(isar, schemas),
        );

  static List<DocumentCollection> Function() _bindings(
    Isar isar,
    List<CollectionSchema<Object?>> schemas,
  ) {
    final bindings = [for (final s in schemas) IsarCollectionBinding(isar, s)];
    return () => bindings;
  }

  final Isar isar;

  @override
  Future<DatabaseMetadata> getMetadata() async {
    final base = await super.getMetadata();
    return DatabaseMetadata(
      engine: base.engine,
      engineVersion: base.engineVersion,
      path: isar.path,
      sizeBytes: isar.isOpen ? await isar.getSize() : null,
      extra: {...base.extra, 'name': isar.name},
    );
  }
}

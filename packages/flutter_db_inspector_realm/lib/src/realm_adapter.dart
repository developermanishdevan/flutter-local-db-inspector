import 'dart:io';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:realm_dart/realm.dart';

import 'realm_collection.dart';

/// Inspects an open [Realm] through Realm's dynamic API; no per-class code
/// is needed.
///
/// Every top-level class of `realm.schema` becomes a collection (embedded
/// classes are shown inline in their parents):
///
/// ```dart
/// final realm = Realm(Configuration.local([Person.schema, Dog.schema]));
/// DbInspector.registerDatabase(name: 'realm', adapter: RealmAdapter(realm));
/// ```
class RealmAdapter extends DocumentAdapter {
  RealmAdapter(this.realm, {super.maxScanDocuments})
      : super(
          type: 'realm',
          engine: 'realm',
          collections: () => collectionsOf(realm),
        );

  final Realm realm;

  /// Collections for the top-level classes of [realm]'s current schema.
  static List<RealmCollection> collectionsOf(Realm realm) => [
        if (!realm.isClosed)
          for (final schema in realm.schema)
            if (schema.baseType == ObjectType.realmObject)
              RealmCollection(realm, schema),
      ];

  @override
  Future<DatabaseMetadata> getMetadata() async {
    final base = await super.getMetadata();
    final path = realm.config.path;
    int? size;
    try {
      final file = File(path);
      if (file.existsSync()) size = file.lengthSync();
    } on FileSystemException {
      size = null;
    }
    return DatabaseMetadata(
      engine: base.engine,
      engineVersion: base.engineVersion,
      path: path,
      sizeBytes: size,
      extra: {
        ...base.extra,
        if (realm.config case final LocalConfiguration local)
          'schemaVersion': local.schemaVersion,
        'inMemory': realm.config is InMemoryConfiguration,
        'closed': realm.isClosed,
      },
    );
  }
}

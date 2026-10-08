import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/utils/database_utils.dart' show getNonEmptyStoreNames;

import 'sembast_store_collection.dart';

/// Inspects a Sembast [Database].
///
/// Each store is a collection. Sembast only knows about stores that hold
/// records, so non-empty stores are discovered automatically (when
/// [discoverStores] is true) and [stores] adds names that should be listed
/// even while empty. With `discoverStores: false` exactly [stores] is shown.
///
/// ```dart
/// DbInspector.registerDatabase(name: 'app', adapter: SembastAdapter(db));
/// ```
class SembastAdapter extends DocumentAdapter {
  SembastAdapter(
    this.database, {
    List<String>? stores,
    bool discoverStores = true,
    super.maxScanDocuments,
  }) : super(
          type: 'sembast',
          engine: 'sembast',
          collections: () => [
            for (final name in _storeNames(database, stores, discoverStores))
              SembastStoreCollection(database, name),
          ],
        );

  final Database database;

  static Set<String> _storeNames(
    Database db,
    List<String>? stores,
    bool discover,
  ) {
    final names = <String>{...?stores};
    if (discover) {
      try {
        names.addAll(getNonEmptyStoreNames(db));
      } on TypeError {
        // Not a built-in Sembast database implementation: only the declared
        // stores can be listed.
      }
    }
    return names;
  }

  @override
  Future<DatabaseMetadata> getMetadata() async {
    final base = await super.getMetadata();
    return DatabaseMetadata(
      engine: base.engine,
      engineVersion: base.engineVersion,
      path: database.path,
      extra: {...base.extra, 'schemaVersion': database.version},
    );
  }
}

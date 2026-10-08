import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:get_storage/get_storage.dart';

import 'get_storage_store.dart';

/// Inspects GetStorage containers, one entity (kind `box`) per container.
///
/// ```dart
/// GetStorageAdapter({'GetStorage': GetStorage(), 'cache': GetStorage('cache')});
/// ```
///
/// Containers must be initialised (`await GetStorage.init(name)`) first.
class GetStorageAdapter extends KeyValueAdapter {
  /// Inspects [containers], keyed by container name.
  GetStorageAdapter(Map<String, GetStorage> containers)
      : super(
          type: 'get_storage',
          stores: () => [
            for (final e in containers.entries)
              GetStorageStore(e.value, name: e.key),
          ],
        );
}

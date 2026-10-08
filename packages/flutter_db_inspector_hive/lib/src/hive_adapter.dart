import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:hive_ce/hive_ce.dart';

import 'hive_box_store.dart';

/// Inspects Hive boxes and lazy boxes.
///
/// Each open box is one entity (kind `box`); closed boxes are skipped. Rows
/// are `key`, `value` and `type` columns, keys are Hive's `int` or `String`
/// keys.
///
/// ```dart
/// DbInspector.registerDatabase(
///   name: 'hive',
///   adapter: HiveAdapter([settingsBox, cacheLazyBox]),
/// );
/// ```
class HiveAdapter extends KeyValueAdapter {
  /// Inspects a fixed set of [boxes].
  ///
  /// [decode] is applied to every box; see [HiveBoxStore.decode].
  HiveAdapter(Iterable<BoxBase<Object?>> boxes, {HiveDecode? decode})
      : this.dynamic(() => boxes, decode: decode);

  /// Inspects the boxes returned by [boxes] at the time of each request, so
  /// boxes opened later appear without re-registering the adapter.
  HiveAdapter.dynamic(
    Iterable<BoxBase<Object?>> Function() boxes, {
    HiveDecode? decode,
  }) : super(
          type: 'hive',
          engine: 'hive_ce',
          stores: () => [
            for (final box in boxes())
              if (box.isOpen) HiveBoxStore(box, decode: decode),
          ],
        );
}

/// Hive (`hive_ce`) adapter for Flutter DB Inspector.
///
/// ```dart
/// final settings = await Hive.openBox('settings');
/// DbInspector.registerDatabase(
///   name: 'hive',
///   adapter: HiveAdapter([settings]),
/// );
/// ```
library;

export 'src/hive_adapter.dart';
export 'src/hive_box_store.dart';

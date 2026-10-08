/// Flutter DB Inspector — inspect your app's local databases from DevTools,
/// VS Code and Android Studio while it runs.
///
/// One import gives you the runtime and every connector:
///
/// ```dart
/// import 'package:flutter_db_inspector/flutter_db_inspector.dart';
///
/// DbInspector.initialize(
///   enabled: kDebugMode,
///   databases: [
///     InspectorDatabase(name: 'app_database', adapter: SqliteAdapter(db)),
///     InspectorDatabase(name: 'cache', adapter: HiveAdapter([box])),
///   ],
/// );
/// ```
///
/// | Storage | Connector |
/// |---|---|
/// | sqflite / sqflite_common_ffi / Floor | `SqliteAdapter(db)` |
/// | Drift | `DriftAdapter(db)` |
/// | Isar (`isar_community`) | `IsarAdapter(isar, schemas)` |
/// | ObjectBox | `ObjectBoxAdapter(store, collections)` |
/// | Realm | `RealmAdapter(realm)` |
/// | Sembast | `SembastAdapter(db)` |
/// | Hive (`hive_ce`) | `HiveAdapter(boxes)` |
/// | SharedPreferences | `SharedPreferencesAdapter(prefs)` |
/// | flutter_secure_storage | `SecureStorageAdapter(storage)` |
/// | GetStorage | `GetStorageAdapter(containers)` |
library;

export 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
export 'package:flutter_db_inspector_drift/flutter_db_inspector_drift.dart';
export 'package:flutter_db_inspector_get_storage/flutter_db_inspector_get_storage.dart';
export 'package:flutter_db_inspector_hive/flutter_db_inspector_hive.dart';
export 'package:flutter_db_inspector_isar/flutter_db_inspector_isar.dart';
export 'package:flutter_db_inspector_objectbox/flutter_db_inspector_objectbox.dart';
export 'package:flutter_db_inspector_realm/flutter_db_inspector_realm.dart';
export 'package:flutter_db_inspector_secure_storage/flutter_db_inspector_secure_storage.dart';
export 'package:flutter_db_inspector_sembast/flutter_db_inspector_sembast.dart';
export 'package:flutter_db_inspector_shared_preferences/flutter_db_inspector_shared_preferences.dart';
export 'package:flutter_db_inspector_sqlite/flutter_db_inspector_sqlite.dart';

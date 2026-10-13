/// Flutter DB Inspector: inspect your app's local databases from DevTools,
/// VS Code and Android Studio while it runs.
///
/// This library is the runtime ([DbInspector], the adapter contract and the
/// generic document and key-value engines) plus the wire protocol. Add one
/// connector package per storage the app uses:
///
/// ```dart
/// import 'package:flutter_db_inspector/flutter_db_inspector.dart';
/// import 'package:flutter_db_inspector_sqlite/flutter_db_inspector_sqlite.dart';
///
/// DbInspector.initialize(
///   enabled: kDebugMode,
///   databases: [
///     InspectorDatabase(name: 'app_database', adapter: SqliteAdapter(db)),
///   ],
/// );
/// ```
///
/// Tools that only speak the protocol can import
/// `package:flutter_db_inspector/protocol.dart` instead.
library;

export 'protocol.dart';

export 'src/adapter.dart';
export 'src/common/in_memory_query.dart';
export 'src/config.dart';
export 'src/db_inspector.dart';
export 'src/document/document_adapter.dart';
export 'src/document/document_collection.dart';
export 'src/key_value/key_value_adapter.dart';
export 'src/key_value/key_value_store.dart';
export 'src/registry.dart';
export 'src/router.dart';

/// Flutter DB Inspector runtime.
///
/// ```dart
/// DbInspector.initialize(enabled: kDebugMode);
/// DbInspector.registerDatabase(name: 'app', adapter: SqliteAdapter(db));
/// ```
library;

export 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

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

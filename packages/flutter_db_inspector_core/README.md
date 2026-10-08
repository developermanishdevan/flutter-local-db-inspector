# flutter_db_inspector_core

Runtime core of [Flutter DB Inspector](https://pub.dev/packages/flutter_db_inspector):
`DbInspector`, the database registry, the request router, the Dart VM service
extension, and the generic SQL, document and key-value engines that the
adapters build on.

Most apps should depend on
[`flutter_db_inspector`](https://pub.dev/packages/flutter_db_inspector), which
includes this package and every connector.

## Use it directly

Depend on the core plus only the connectors you use, to keep unused plugins
out of your app:

```yaml
dependencies:
  flutter_db_inspector_core: ^1.0.0
  flutter_db_inspector_sqlite: ^1.0.0
```

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_sqlite/flutter_db_inspector_sqlite.dart';

DbInspector.initialize(
  enabled: kDebugMode,
  databases: [
    InspectorDatabase(name: 'app_database', adapter: SqliteAdapter(db)),
  ],
);
```

## Write your own adapter

Extend `DbAdapter`, or start from `DocumentAdapter` / `KeyValueAdapter` to get
filtering, sorting and paging for free, then register it with
`DbInspector.registerDatabase`. See
[docs/database_adapters.md](https://github.com/developermanishdevan/flutter-local-db-inspector/blob/main/docs/database_adapters.md).

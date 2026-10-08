<p align="center"><img src="https://raw.githubusercontent.com/developermanishdevan/flutter-local-db-inspector/main/Imges/image.jpg" alt="Flutter DB Inspector" width="200"></p>

# flutter_db_inspector

Inspect, query, edit and export your Flutter app's local storage **while the
app runs**, from DevTools, VS Code or Android Studio. No need to find database
files on a device, copy them off, or open them in a separate SQLite browser.

```
Run Flutter app → Open Flutter DB Inspector → Database → Table → Rows → Search / Filter / Edit / Query
```

This is the one package apps add: it includes every connector and ships the
**DevTools extension**.

## Supported storage

| Data model | Engines | Browsed as | Query |
|---|---|---|---|
| **relational** | SQLite, sqflite, sqflite_common_ffi, Floor, Drift | tables & views · rows | SQL console |
| **document** | Isar, ObjectBox, Realm, Sembast | collections · objects | filter / sort / search |
| **keyValue** | Hive, SharedPreferences, Secure Storage, GetStorage | boxes · entries | filter / sort / search |

## Install

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
```

## Set up

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_db_inspector/flutter_db_inspector.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openDatabase('app.db');
  final cache = await Hive.openBox('cache');

  DbInspector.initialize(
    enabled: kDebugMode,
    databases: [
      InspectorDatabase(name: 'app_database', adapter: SqliteAdapter(db)),
      InspectorDatabase(name: 'cache', adapter: HiveAdapter([cache])),
    ],
  );

  runApp(const MyApp());
}
```

Databases opened later can still be added with
`DbInspector.registerDatabase(name: ..., adapter: ...)`.

## Open the inspector

Run the app in debug mode, then use any of:

- **DevTools:** open the **flutter_db_inspector** tab. The extension ships in
  this package, so there is nothing else to install. Enable it the first time
  DevTools asks.
- **VS Code:** the **Flutter DB** view ([install the extension](https://marketplace.visualstudio.com/items?itemName=developer-manishdevan.flutter-db-inspector)).
- **Android Studio / IntelliJ:** the **Flutter DB** tool window ([install the plugin](https://plugins.jetbrains.com/plugin/34899-flutter-db-inspector)).

## Features

- Database tree, data grid with filter, sort and search
- Insert, update and delete rows; clear tables
- Schema view, SQL console with history, statistics
- Export (VS Code and Android Studio)

## Security

This is a development tool:

- Disabled in release builds; it never opens a network port. Clients talk to
  the app only through the Dart VM service.
- `DbInspector.initialize(readOnly: true)` blocks every write.
- `sensitiveColumns` masks values; Secure Storage values are masked by default.

## Smaller apps

This package also brings in the SharedPreferences, Secure Storage and
GetStorage plugins and Drift's bundled SQLite, even when your app doesn't use
them. Size-sensitive apps can depend on
[`flutter_db_inspector_core`](https://pub.dev/packages/flutter_db_inspector_core)
plus only the connectors they use.

## More

- [Getting started](https://github.com/developermanishdevan/flutter-local-db-inspector/blob/main/docs/getting_started.md)
- [DevTools extension](https://github.com/developermanishdevan/flutter-local-db-inspector/blob/main/docs/devtools.md)
- [Security](https://github.com/developermanishdevan/flutter-local-db-inspector/blob/main/docs/security.md)
- [Report an issue](https://github.com/developermanishdevan/flutter-local-db-inspector/issues)

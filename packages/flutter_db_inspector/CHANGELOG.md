## 2.0.0

**Breaking.** This package is now the runtime, the wire protocol and the
DevTools extension. Connectors are no longer bundled.

- `flutter_db_inspector_core` and `flutter_db_inspector_protocol` are merged
  into this package and will not get further releases. The protocol alone is
  available as `package:flutter_db_inspector/protocol.dart`.
- No connector is re-exported any more, so the package no longer pulls in
  Realm, Isar, ObjectBox or any other database. Apps whose code generators
  need a newer `analyzer` / `build` / `source_gen` (for example
  `retrofit_generator` 10) can now depend on it, and it compiles for Flutter
  web.
- Pure Dart: no Flutter SDK dependency.

### Migrating from 1.x

1. Keep `flutter_db_inspector: ^2.0.0` and add one connector per storage the
   app uses, for example `flutter_db_inspector_drift: ^2.0.0`.
2. Import each connector next to the main library:
   `import 'package:flutter_db_inspector_drift/flutter_db_inspector_drift.dart';`
3. If you depended on `flutter_db_inspector_core` (or `_protocol`), replace it
   with `flutter_db_inspector: ^2.0.0` and change
   `package:flutter_db_inspector_core/flutter_db_inspector_core.dart` imports
   to `package:flutter_db_inspector/flutter_db_inspector.dart`.

## 1.0.0

- Initial release.
- Single package that bundles every connector: SQLite (sqflite, sqflite_common_ffi, Floor), Drift, Isar, ObjectBox, Realm, Sembast, Hive, SharedPreferences, Secure Storage and GetStorage.
- Inspect, query and edit local databases from DevTools, VS Code and Android Studio while the app runs.
- Ships the prebuilt DevTools extension in `extension/devtools`.
- Disabled in release builds, opens no network port, and supports read-only mode and value masking.

# Changelog

All notable changes to Flutter DB Inspector. Each package under `packages/`
also keeps its own `CHANGELOG.md`, which is what pub.dev shows.

## 1.0.0

Initial release.

### Runtime packages (pub.dev)

- `flutter_db_inspector`: one package that bundles every connector and ships
  the prebuilt DevTools extension.
- `flutter_db_inspector_protocol`: wire protocol shared by the runtime and all
  clients.
- `flutter_db_inspector_core`: `DbInspector`, registry, router, VM service
  extension and the generic SQL, document and key-value engines.
- Adapters:
  - `flutter_db_inspector_sqlite` (sqflite, sqflite_common_ffi, Floor)
  - `flutter_db_inspector_drift`
  - `flutter_db_inspector_isar`
  - `flutter_db_inspector_objectbox`
  - `flutter_db_inspector_realm`
  - `flutter_db_inspector_sembast`
  - `flutter_db_inspector_hive`
  - `flutter_db_inspector_shared_preferences`
  - `flutter_db_inspector_secure_storage`
  - `flutter_db_inspector_get_storage`

### Tools

- DevTools extension (`flutter_db_inspector_devtools`), built into
  `flutter_db_inspector/extension/devtools`.
- `flutter_db_inspector_client`: pure Dart VM service client used by the
  DevTools extension.
- VS Code extension (`integrations/vscode/flutter-db-inspector`).
- Android Studio plugin (`integrations/android-studio/flutter-db-inspector`).

### Safety

- Disabled in release builds and never opens a network port.
- Read-only mode and value masking.

# Changelog

All notable changes to Flutter DB Inspector. Each package under `packages/`
also keeps its own `CHANGELOG.md`, which is what pub.dev shows.

## 2.0.0

### Runtime packages (pub.dev)

- **Breaking:** `flutter_db_inspector` is now the runtime, the wire protocol
  and the DevTools extension in one pure Dart package.
  `flutter_db_inspector_core` and `flutter_db_inspector_protocol` are merged
  into it and discontinued.
- **Breaking:** connectors are opt-in and no longer re-exported. Apps add
  `flutter_db_inspector` plus one connector per storage they use, so Realm,
  Isar and ObjectBox (and their pinned code generators) only reach apps that
  use them. This fixes dependency resolution next to newer code generators
  such as `retrofit_generator` 10, and lets the DevTools extension work in
  Flutter web apps.
- Every connector is 2.0.0 and depends on `flutter_db_inspector` ^2.0.0.
- Migration steps: `packages/flutter_db_inspector/CHANGELOG.md`.

### Tools (VS Code extension, Android Studio plugin, DevTools extension: 2.0.0)

- Saved SQL queries are kept per app, keyed by the app's Dart package name
  (read from the running app; no code change), until the user deletes them.
  Other apps' saved queries stay listed. VS Code keeps them in its global
  state, Android Studio in its application settings, DevTools in the
  project's `.dart_tool/` (through the Dart Tooling Daemon) or the browser.
- Saving under an existing name replaces that query. Saved queries can be
  loaded, run again or deleted from the SQL console (Android Studio,
  DevTools) or the Queries view (VS Code); history entries can be saved.
- Fixed: in the SQL console's side panel, the Run and Delete buttons also
  loaded the query into the editor.

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

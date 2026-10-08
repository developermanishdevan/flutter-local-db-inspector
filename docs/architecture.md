# Architecture

```
┌────────────────────────── Flutter app (debug build) ───────────────────────────┐
│  DbInspector.initialize / registerDatabase                                      │
│        │                                                                         │
│   DbRegistry ──► InspectorRouter ──► DbAdapter                                   │
│        │          • versions            ├─ SqliteAdapter (SqliteExecutor)        │
│        │          • capabilities        │     ├─ sqflite / FFI / Floor          │
│        │          • read-only mode      │     └─ DriftAdapter (DriftExecutor)    │
│        │          • masking             ├─ DocumentAdapter (DocumentCollection)  │
│        │          • limits & timeouts   │     ├─ Isar · ObjectBox · Realm · Sembast
│        │          • error mapping       └─ KeyValueAdapter (KeyValueStore)       │
│        │                                      ├─ Hive · SharedPreferences       │
│        ▼                                      └─ Secure Storage · GetStorage    │
│  ext.flutter_db_inspector.request  (dart:developer service extension)           │
│  flutter_db_inspector.databasesChanged  (Extension stream event)                │
└───────────────────────────────────────┬─────────────────────────────────────────┘
                                         │  Dart VM service (WebSocket, via DDS)
              ┌──────────────────────────┼──────────────────────────┐
         VS Code extension        DevTools extension        Android Studio plugin
         (implemented)            (implemented)             (implemented)
```

## Principles

1. **Clients never touch database files.** Every read and write runs inside the app, through the app's own database connection. This avoids per-platform file paths and permissions, and works the same on Android, iOS, desktop and emulators.
2. **One protocol for every client.** All clients send the same JSON requests to one VM service extension, as described in [protocol.md](protocol.md).
3. **No SQL assumption.** Every adapter reports a `dataModel` (`relational`, `document` or `keyValue`) and a set of `capabilities`. Clients use the data model for wording and layout, and the capabilities for behaviour. No client contains engine-specific code.
4. **Database-specific behaviour lives in adapters. Cross-cutting policy lives in the router.** Permissions, masking, paging limits, response budgets, timeouts and error mapping are enforced in one place, so adapters can't bypass them.
5. **Bounded everything.** Pages are capped at 100 rows. Responses are capped at 5 MB, and a response that's too large is re-encoded with compact previews before failing. Large values are truncated *inside the engine* where possible (for example SQLite `substr`) and streamed on demand with `value.read`.

## Engines

| Engine family | Implemented by | Extension point |
|---|---|---|
| SQL | `SqliteAdapter` | `SqliteExecutor` (select, modify, insert, execute) |
| Document | `DocumentAdapter` | `DocumentCollection` (count, list, get, insert, update, delete, clear, optional native `query`) |
| Key-value | `KeyValueAdapter` | `KeyValueStore` (keys, get, put, delete, clear) |

A new storage library normally needs only one small binding class. Engines that can't filter natively fall back to bounded in-memory evaluation, limited by `maxScanDocuments` so a scan never stalls the app.

## Connection lifecycle (clients)

```
DISCONNECTED → CONNECTING → (find isolate with the extension) → CONNECTED
CONNECTED → IsolateExit (hot restart) → RECONNECTING → ServiceExtensionAdded → CONNECTED
any → WebSocket closed (app stopped) → DISCONNECTED
```

Requests made while reconnecting wait for the app to come back instead of failing. The VS Code implementation is `ConnectionManager` in `integrations/vscode/flutter-db-inspector/src/connection`. It has no VS Code dependency and is tested against a real Dart VM, including real Flutter hot restarts. Its Dart port, used by the DevTools extension, is `InspectorConnection` in `packages/flutter_db_inspector_client`, tested against the same demo server.

## Repository layout

```
packages/                   runtime, protocol and adapter packages
integrations/vscode/        VS Code extension (TypeScript)
integrations/android-studio/ Android Studio / IntelliJ plugin (Kotlin)
shared/web-ui/              data UI shared by the IDE integrations (TypeScript, no framework)
examples/sqlite_example/    Flutter demo app (SQLite + Hive + SharedPreferences)
docs/                       this documentation
tool/check.sh               format, analyze and test everything
```

Every package resolves on its own. A `pubspec_overrides.yaml` in each package points the other inspector packages at their local folders, so local builds use local code while the published pubspecs use `^1.0.0` constraints. (A single pub workspace is not possible: the Isar, Realm and Drift code generators need incompatible `analyzer` / `source_gen` versions.)

# flutter_db_inspector_get_storage

[GetStorage](https://pub.dev/packages/get_storage) adapter for Flutter DB
Inspector. Browse, search and edit GetStorage containers while your app runs.

## Install

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
  flutter_db_inspector_get_storage: ^1.0.0
```

## Register

```dart
await GetStorage.init();
await GetStorage.init('cache');

DbInspector.initialize(enabled: kDebugMode);
DbInspector.registerDatabase(
  name: 'storage',
  adapter: GetStorageAdapter({
    'GetStorage': GetStorage(),
    'cache': GetStorage('cache'),
  }),
);
```

Each container is an entity with `key`, `value` and `type` columns.

## Limitations

- `GetStorage` does not expose its container name, so containers are passed
  as a name → instance map.
- Values are persisted as JSON: inserts and updates accept JSON values only,
  and custom objects held in memory by the app (shown through `toJson()`) are
  not overwritten with plain JSON (`UNSUPPORTED_OPERATION`).
- Filtering, sorting and search run in memory.

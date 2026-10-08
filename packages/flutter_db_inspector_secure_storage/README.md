# flutter_db_inspector_secure_storage

[flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage)
adapter for Flutter DB Inspector. Lists the keys in secure storage and lets
you add, edit and delete entries while your app runs. **Values are masked by
default.**

## Install

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
  flutter_db_inspector_secure_storage: ^1.0.0
```

## Register

```dart
DbInspector.initialize(enabled: kDebugMode);
DbInspector.registerDatabase(
  name: 'secrets',
  adapter: SecureStorageAdapter(const FlutterSecureStorage()),
);

// Only on a development build where showing secrets is acceptable:
SecureStorageAdapter(const FlutterSecureStorage(), revealValues: true);
```

All entries appear in one entity named `secure_storage` with `key`, `value`
and `type` columns.

## Masking

With `revealValues: false` (the default) values are never read from secure
storage for display: rows show them as masked, search and filters cannot
match their content, and `value.read` is refused with `PERMISSION_DENIED`.
Writes are still allowed, so a token can be replaced without being revealed.

## Limitations

- Only string values can be written (`INVALID_REQUEST` otherwise).
- Keys are listed through `readAll()`, which is asynchronous; the adapter
  reloads the key list at the start of every request.
- Platform options (`AndroidOptions`, `IOSOptions`, ...) are those of the
  `FlutterSecureStorage` instance you pass in.
- Clearing the entity calls `deleteAll()`, which removes every entry visible
  to those options.
- While masked, the `type` column shows `MaskedValue` instead of `String`.

# flutter_db_inspector_shared_preferences

[shared_preferences](https://pub.dev/packages/shared_preferences) adapter for
Flutter DB Inspector. Browse, search and edit preferences while your app runs.
Supports the legacy `SharedPreferences` API, `SharedPreferencesAsync` and
`SharedPreferencesWithCache`.

## Install

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
  flutter_db_inspector_shared_preferences: ^1.0.0
```

## Register

```dart
DbInspector.initialize(enabled: kDebugMode);

// Legacy API
DbInspector.registerDatabase(
  name: 'prefs',
  adapter: SharedPreferencesAdapter(await SharedPreferences.getInstance()),
);

// Async API (optionally restricted with an allow list)
DbInspector.registerDatabase(
  name: 'prefs',
  adapter: SharedPreferencesAdapter.async(SharedPreferencesAsync()),
);

// Cached API
DbInspector.registerDatabase(
  name: 'prefs',
  adapter: SharedPreferencesAdapter.withCache(prefsWithCache),
);
```

All preferences appear in one entity named `shared_preferences` with `key`,
`value` and `type` columns.

## Writes

- Updates keep the stored type: an `int` stays an `int`, a `double` stays a
  `double`, and so on. Numeric or boolean text (`"42"`, `"true"`) is accepted
  when it fits; anything else is rejected with `INVALID_REQUEST`.
- Inserts infer the type from the value: `bool`, `int`, `double`, `String`,
  or a JSON list of strings (stored with `setStringList`).

## How the async API is read

`SharedPreferencesAsync` has no synchronous cache, but the inspector's
key/value engine lists keys synchronously. The adapter therefore reloads a
snapshot (`getAll`) at the start of every request and keeps it in sync with
its own writes, so each request reflects current platform data.

## Limitations

- The legacy and cached APIs are read from the app's in-memory cache; changes
  made by native code or other isolates appear after the app reloads it.
- Keys outside a `SharedPreferencesWithCache`/async allow list are not shown
  and cannot be written.
- Clearing the entity clears every key the adapter can see (for the legacy
  API: every key with the configured prefix).

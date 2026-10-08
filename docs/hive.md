# Hive and key-value stores

```dart
DbInspector.registerDatabase(name: 'cache', adapter: HiveAdapter([userBox, settingsBox]));
// Boxes opened later:
DbInspector.registerDatabase(name: 'cache', adapter: HiveAdapter.dynamic(() => myOpenBoxes));
```

Key-value stores are shown as **boxes** of **entries** with three columns: `key`, `value` and `type`, where `type` is the runtime type such as `String`, `Map` or `Person`.

```
Boxes
▾ userBox
   key: 1   {"name": "Asha", "age": 31}   Person
   key: 2   …
```

- Supports Box and LazyBox, and int or String keys.
- You can search, filter and sort by key, value or type. Edit, add, delete, clear and export entries.
- Custom objects stored through a `TypeAdapter` are displayed through their `toJson()`. They can only be overwritten if you pass a `decode` callback; otherwise the adapter refuses, so a `Person` is never silently replaced with a `Map`.
- The adapter uses **`hive_ce`**. For classic `hive` 2.x, implement the ~15-line `KeyValueStore` shown in the package README.

The same engine powers SharedPreferences (editing keeps each value's type), flutter_secure_storage (masked by default) and GetStorage.

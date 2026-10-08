# Isar

```dart
final isar = await Isar.open([UserSchema, PostSchema], directory: dir.path);
DbInspector.registerDatabase(name: 'isar', adapter: IsarAdapter(isar, [UserSchema, PostSchema]));
```

The adapter uses **`isar_community`**, the maintained fork. The original `isar` package (3.1.0) is pinned to Dart 2 and no longer maintained.

- Collections become entities of kind `collection`. The id property comes first, then the properties with their Isar types; embedded objects and lists are shown as JSON. Indexes, including composite and unique ones, are listed.
- Filters run as native Isar queries where Isar can evaluate them exactly: strings, ints, bools and null checks. Everything else falls back to the bounded in-memory engine.
- Writes run in `writeTxn` and are type-checked against the schema.
- Links aren't shown, because Isar's JSON export omits them.

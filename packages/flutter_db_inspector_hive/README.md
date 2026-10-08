# flutter_db_inspector_hive

[Hive CE](https://pub.dev/packages/hive_ce) adapter for Flutter DB Inspector.
Browse, search, filter, sort and edit open `Box`es and `LazyBox`es while your
app runs.

## Install

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
  flutter_db_inspector_hive: ^1.0.0
```

## Register

```dart
final settings = await Hive.openBox('settings');
final cache = await Hive.openLazyBox('cache');

DbInspector.initialize(enabled: kDebugMode);
DbInspector.registerDatabase(
  name: 'hive',
  adapter: HiveAdapter([settings, cache]),
);

// Or resolve boxes on every request, so boxes opened later show up:
DbInspector.registerDatabase(
  name: 'hive',
  adapter: HiveAdapter.dynamic(() => myOpenBoxes),
);
```

Each open box is an entity with `key`, `value` and `type` columns. Custom
objects stored through a `TypeAdapter` are shown through their `toJson()`.

### Editing custom objects

Writing plain JSON over a custom object would silently change the stored type,
so it is refused (`UNSUPPORTED_OPERATION`) unless you provide a `decode`
callback:

```dart
HiveAdapter(
  [peopleBox],
  decode: (json, previous) => previous is Person || previous == null
      ? Person.fromJson(json! as Map)
      : json,
);
```

Use `KeyValueAdapter(type: 'hive', stores: () => [HiveBoxStore(box, decode: ...)])`
for per-box callbacks.

## Classic `hive` (2.x)

This package depends on `hive_ce`, the maintained successor of `hive`. If you
still use classic `hive` 2.2.3, implement the binding yourself:

```dart
final class ClassicHiveStore extends KeyValueStore {
  ClassicHiveStore(this.box);
  final Box<Object?> box; // from package:hive

  @override String get name => box.name;
  @override int get length => box.length;
  @override Iterable<Object> get keys => box.keys.cast<Object>();
  @override bool containsKey(Object key) => box.containsKey(key);
  @override Object? get(Object key) => box.get(key);
  @override Future<void> put(Object key, Object? value) => box.put(key, value);
  @override Future<void> delete(Object key) => box.delete(key);
  @override Future<int> clear() => box.clear();
}

KeyValueAdapter(type: 'hive', stores: () => [ClassicHiveStore(box)]);
```

## Limitations

- Only open boxes are listed; closed boxes are skipped.
- Filtering, sorting and search run in memory. For lazy boxes this reads every
  value from disk, so plain paging is preferred on large lazy boxes.
- Typed boxes (e.g. `Box<int>`) reject values of another type
  (`INVALID_REQUEST`).
- Custom objects without `toJson()` are shown as their `toString()`.

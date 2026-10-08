# flutter_db_inspector_objectbox

[ObjectBox](https://pub.dev/packages/objectbox) adapter for Flutter DB
Inspector.

ObjectBox's Dart API is generated per entity and has no untyped access, so
each box is registered with a small typed binding that converts objects to
and from JSON-like maps.

## Install

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
  flutter_db_inspector_objectbox: ^1.0.0
  objectbox: ^5.0.0
```

## Register

```dart
import 'package:flutter_db_inspector/flutter_db_inspector.dart';
import 'package:flutter_db_inspector_objectbox/flutter_db_inspector_objectbox.dart';

final store = await openStore();

DbInspector.initialize(enabled: kDebugMode);
DbInspector.registerDatabase(
  name: 'objectbox',
  adapter: ObjectBoxAdapter(store, [
    ObjectBoxCollection<Task>(
      store.box<Task>(),
      name: 'Task',
      toJson: (t) => {'id': t.id, 'title': t.title, 'due': t.due},
      fromJson: (j) => Task(
        id: j['id'] as int? ?? 0, // 0 = let ObjectBox assign an id
        title: j['title'] as String? ?? '',
        due: j['due'] as DateTime?,
      ),
      getId: (t) => t.id,
    ),
  ]),
);
```

* `toJson` values may be `int`, `double`, `String`, `bool`, `DateTime`,
  `Uint8List`, lists and maps.
* `fromJson` receives the whole document: on update the stored object's
  `toJson()` merged with the edited fields. Throwing a `TypeError` (e.g. a
  failed cast) is reported to the client as an invalid value.
* Pass `fields` to declare columns; otherwise they are inferred from stored
  objects. Use `idField` if the id is not called `id`.

## Limitations

* Filtering, sorting and search run in memory in the generic engine (bounded
  by `maxScanDocuments`), because ObjectBox query conditions require the
  generated `Entity_` properties. Paging and counts use ObjectBox queries.
* Relations (`ToOne`/`ToMany`) are only shown if your `toJson` includes them.
* Inserting with an explicit id requires `@Id(assignable: true)`.

## Tests

The tests use a real ObjectBox store. On the first run they download the
objectbox-c library for the host (macOS or Linux) into `.dart_tool/objectbox`
and load it into the test process; they are tagged `native`
(`dart test -x native` skips them). Regenerate `test/objectbox.g.dart` with
`dart run build_runner build`.

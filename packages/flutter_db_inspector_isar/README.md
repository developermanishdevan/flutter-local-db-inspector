# flutter_db_inspector_isar

[Isar](https://pub.dev/packages/isar_community) adapter for Flutter DB
Inspector. Browse, filter, sort and edit every collection of an Isar instance
without writing per-collection code.

> **Why `isar_community`?** The original `isar` package (3.1.0) is abandoned
> and predates Dart 3; it no longer builds with current SDKs and analyzers.
> This adapter targets [`isar_community`](https://pub.dev/packages/isar_community),
> the maintained fork with the same API (`import 'package:isar_community/isar.dart'`).

## Install

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
  flutter_db_inspector_isar: ^1.0.0
  isar_community: ^3.3.0
```

## Register

Isar has no public API listing the collections of an open instance, so pass
the same schemas you gave to `Isar.open`:

```dart
import 'package:flutter_db_inspector/flutter_db_inspector.dart';
import 'package:flutter_db_inspector_isar/flutter_db_inspector_isar.dart';

final schemas = [UserSchema, NoteSchema];
final isar = await Isar.open(schemas, directory: dir.path);

DbInspector.initialize(enabled: kDebugMode);
DbInspector.registerDatabase(name: 'isar', adapter: IsarAdapter(isar, schemas));
```

## How data is shown

* Each collection is an entity of kind `collection`; rows are objects keyed by
  their `Id` property (its real name, e.g. `id` or `noteId`).
* Columns come from the generated schema: scalar properties keep their type,
  `DateTime` is shown as a date-time, `List<byte>` as bytes, other lists and
  embedded objects as JSON. Enum properties show the stored value; the
  declared type lists the enum mapping (e.g. `Byte enum(calm=0, happy=1)`).
* Indexes (including composite and unique ones) are listed.
* Objects are read with `exportJson` and written with `importJson` inside
  `writeTxn`, so updates go through Isar (indexes, unique constraints).
  Updates merge the edited fields into the stored object.
* Filters, sorting, paging and counts run as native Isar queries for
  string/integer/bool/id properties and null checks. Free-text search, filters
  on floating point, `DateTime`, list and embedded properties, and sorting on
  lists/objects are evaluated in memory by the generic engine (bounded by
  `maxScanDocuments`).

## Limitations

* `IsarLink`/`IsarLinks` are not shown or edited (Isar's JSON export does not
  include links); editing an object leaves its links untouched.
* Native queries use Isar's `buildQuery`, which Isar marks experimental.
* Unique index violations are reported as `TRANSACTION_FAILED`.
* Isar Web is not supported (Isar 3 on the web is not production-ready).

## Tests

`dart test` downloads the Isar Core binary for the host into
`.dart_tool/isar_core` on the first run (network required). The test schema
lives in `test/models.dart`; regenerate `test/models.g.dart` with
`dart run build_runner build`.

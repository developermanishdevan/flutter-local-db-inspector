# flutter_db_inspector_sembast

[Sembast](https://pub.dev/packages/sembast) adapter for Flutter DB Inspector.
Pure Dart: works with `sembast`, `sembast_web` and `sembast_sqflite`
databases.

## Install

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
  flutter_db_inspector_sembast: ^1.0.0
```

## Register

```dart
import 'package:flutter_db_inspector/flutter_db_inspector.dart';
import 'package:flutter_db_inspector_sembast/flutter_db_inspector_sembast.dart';

final db = await databaseFactoryIo.openDatabase(path);
DbInspector.initialize(enabled: kDebugMode);
DbInspector.registerDatabase(
  name: 'app',
  // Non-empty stores are discovered; list stores that may be empty.
  adapter: SembastAdapter(db, stores: ['drafts']),
);
```

Pass `discoverStores: false` to show exactly the `stores` you list.

## How data is shown

* Every store is a collection; each record is a row addressed by its key in
  the `_key` column (Sembast's `Field.key`). `int` and `String` keys are both
  supported.
* Map records show one column per field. Sembast is schemaless, so columns are
  inferred from the stored records.
* Records that are not maps (`StoreRef<String, String>`, counters, lists, ...)
  are shown in a single `_value` column (Sembast's `Field.value`) and are
  edited through it.
* Sembast `Timestamp` and `Blob` values are shown as date-times and bytes, and
  date-times/bytes entered in the inspector are stored as `Timestamp`/`Blob`.
* Inserting without a `_key` generates one of the store's key type (`String`
  when existing keys are strings, otherwise an auto-incremented `int`).

Filtering, sorting, paging and counting run inside Sembast (`Finder`,
`Filter`, `SortOrder`). Free-text search, and queries on `_value`, are
evaluated by the generic engine.

## Limitations

* Sembast does not record empty stores, so they appear only when listed in
  `stores`.
* Only top-level fields are columns; nested maps are shown (and edited) as
  JSON.
* A map record field literally named `_key` or `_value` is shadowed by the
  inspector's key/value columns.
* Updates replace the edited fields; the record key cannot be changed.

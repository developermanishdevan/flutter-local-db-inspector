# flutter_db_inspector_realm

[Realm](https://pub.dev/packages/realm) adapter for Flutter DB Inspector.
Browse every Realm class, filter/sort/search objects and edit primitive
properties while your app runs. No per-class code is needed: the adapter
works from `realm.schema` and Realm's dynamic API.

> **Deprecation notice.** MongoDB deprecated the Atlas Device SDKs (including
> Realm for Flutter/Dart) and Device Sync in September 2024. The packages
> still work for local databases but are no longer actively developed. This
> adapter targets the final release line, `realm` / `realm_dart` **20.x**
> (verified with 20.2.0 on Dart 3.11 / Flutter 3.41). Consider planning a
> migration away from Realm for new projects.

## Install

```yaml
dependencies:
  flutter_db_inspector: ^1.0.0
  flutter_db_inspector_realm: ^1.0.0
```

The adapter depends on `realm_dart`, which the Flutter `realm` package itself
builds on, so it works with both Flutter apps (`realm`) and pure Dart programs
(`realm_dart`). Pure Dart programs (and `dart test`) need the native library:
`dart run realm_dart install`.

## Register

```dart
import 'package:flutter_db_inspector/flutter_db_inspector.dart';
import 'package:flutter_db_inspector_realm/flutter_db_inspector_realm.dart';

final realm = Realm(Configuration.local([Person.schema, Address.schema]));
DbInspector.registerDatabase(name: 'realm', adapter: RealmAdapter(realm));
```

The adapter never closes your Realm and must be used on the isolate that
opened it (like any Realm instance). Edits are made in ordinary
`realm.write` transactions, so your `changes` streams and `RealmResults`
listeners update immediately.

## How Realm maps to the inspector

- The database has the `document` data model. Each top-level class
  (`ObjectType.realmObject`) is a collection; embedded classes are shown
  inline inside their parent objects. Computed backlinks are not shown.
- Rows are addressed by the class's primary key (`{"id": 42}`). ObjectId and
  UUID keys are exchanged as strings.
- Value types: `int` → integer; `double`/`float`/`decimal128` → real;
  `string` → text; `bool` → boolean; `date` → dateTime; `data` → blob;
  `objectId`/`uuid` → text; `mixed` → unknown (its unwrapped value); lists,
  sets, maps, links and embedded objects → json. A link is shown as the target
  object's primary key (or `{"$link": "<Class>"}` when the target has no
  primary key); embedded objects are shown as nested maps.
- Paging indexes into live `RealmResults`, so only the requested page is
  read, whatever the collection size.
- Filters and sorts run natively as Realm Query Language when they mean
  exactly the same as the generic in-memory engine: `equals`, `notEquals`,
  `isNull`, `isNotNull` on primitives; numeric comparisons on
  int/float/double; `contains`/`startsWith`/`endsWith` (`[c]`,
  case-insensitive, ASCII patterns) on strings; sorting by
  int/float/double/bool/date. Everything else (text search, string sorting,
  ranges on text/dates, filters on collections) falls back to the in-memory
  engine, which scans the class in batches (bounded by `maxScanDocuments`).

## Writes

- **Update** sets primitive properties of an object found by primary key.
  Values are converted to the property type (e.g. `"9.75"` for a
  `Decimal128`, an ISO-8601 string for a date, a hex string for an
  `ObjectId`); invalid values fail with `INVALID_REQUEST`.
- **Insert** creates the object with `realm.dynamic.create` and sets the
  given primitive properties; unset required properties get Realm's
  defaults. A missing ObjectId/UUID primary key is generated.
- **Delete** removes the object (embedded children are removed with it);
  **clear** deletes every object of the class in one write.
- Editing links, embedded objects, lists, sets or maps fails with
  `UNSUPPORTED_OPERATION`. The primary key cannot be changed.

## Limitations

- Classes **without a primary key are read-only**: they are listed, filtered
  and sorted, but their rows have no key, so they cannot be edited, deleted,
  cleared or opened with `value.read`.
- No SQL console (Realm is not a SQL database).
- Default row order is Realm's natural (storage) order.
- Synchronized (Device Sync) realms are not tested; Device Sync is deprecated.

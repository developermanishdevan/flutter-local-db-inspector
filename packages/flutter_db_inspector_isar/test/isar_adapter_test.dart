import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_isar/flutter_db_inspector_isar.dart';
import 'package:isar_community/isar.dart';
import 'package:test/test.dart';

import 'models.dart';

void main() {
  late Directory dir;
  late Isar isar;
  late InspectorRouter router;
  var instance = 0;

  setUpAll(() async {
    // Real Isar Core, downloaded once into .dart_tool (needs network on the
    // first run).
    final lib = Directory('${Directory.current.path}/.dart_tool/isar_core')
      ..createSync(recursive: true);
    await Isar.initializeIsarCore(
      download: true,
      libraries: {Abi.current(): '${lib.path}/${Abi.current()}.isar'},
    );
    dir = Directory.systemTemp.createTempSync('db_inspector_isar');
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() async {
    isar = await Isar.open(
      [PersonSchema, NoteSchema],
      directory: dir.path,
      name: 'test${instance++}',
      inspector: false,
    );
    await isar.writeTxn(() async {
      for (var i = 0; i < 30; i++) {
        await isar.persons.put(Person()
          ..name = 'P$i'
          ..age = i % 5 == 4 ? null : 20 + i
          ..score = i * 1.5
          ..active = i.isEven
          ..birthday = DateTime.utc(2000 + i)
          ..tags = ['t${i % 3}']
          ..mood = Mood.values[i % 3]
          ..address = i.isEven
              ? (Address()
                ..city = 'Chennai'
                ..zip = '600$i')
              : null);
      }
      for (var i = 1; i <= 3; i++) {
        await isar.notes.put(Note()
          ..title = 'n$i'
          ..author = 'a');
      }
    });
    final registry = DbRegistry()
      ..register('isar', IsarAdapter(isar, [PersonSchema, NoteSchema]));
    router = InspectorRouter(
      registry: registry,
      config: () => const InspectorConfig(mode: InspectorMode.fullAccess),
    );
  });

  tearDown(() => isar.close(deleteFromDisk: true));

  Future<Map<String, Object?>> call(String method,
      [Map<String, Object?> p = const {}]) async {
    return jsonDecode(await router.handleRaw(jsonEncode({
      'method': method,
      'params': {'databaseId': 'isar', ...p},
    }))) as Map<String, Object?>;
  }

  Map<String, Object?> ok(Map<String, Object?> r) {
    expect(r['success'], isTrue, reason: '$r');
    return r['result']! as Map<String, Object?>;
  }

  String errorCode(Map<String, Object?> r) =>
      (r['error']! as Map)['code']! as String;

  Future<Map<String, Object?>> rows(Map<String, Object?> params) =>
      call(Methods.rowsQuery, params).then(ok);

  List<Object?> keys(Map<String, Object?> page) =>
      [for (final r in page['rows']! as List) (r as Map)['key']];

  test('describes the instance, collections and indexes', () async {
    final list = ok(await call(Methods.databaseList));
    final db = (list['databases']! as List).single as Map;
    expect(db['type'], 'isar');
    expect(db['dataModel'], 'document');

    final info = ok(await call(Methods.databaseInfo));
    expect(jsonEncode(info), contains(Isar.version));

    final schema = ok(await call(Methods.schemaList));
    final entities = schema['entities']! as List;
    expect(entities.map((e) => (e as Map)['name']), ['Note', 'Person']);
    expect((entities.last as Map)['kind'], 'collection');
    expect((entities.last as Map)['rowCount'], 30);
    final indexes = {
      for (final i in schema['indexes']! as List) (i as Map)['name']: i,
    };
    expect(indexes['name']!['columns'], ['name']);
    expect(indexes['name']!['unique'], isFalse);
    expect(indexes['title_author']!['columns'], ['title', 'author']);
    expect(indexes['title_author']!['unique'], isTrue);
  });

  test('maps the Isar schema to columns', () async {
    final r = ok(await call(Methods.schemaTable, {'table': 'Person'}));
    final columns = {
      for (final c in (r['schema']! as Map)['columns']! as List)
        (c as Map)['name']: c,
    };
    expect(columns.keys, [
      'id',
      'active',
      'address',
      'age',
      'birthday',
      'mood',
      'name',
      'score',
      'tags',
    ]);
    expect(columns['id']!['primaryKeyPosition'], 1);
    expect(columns['active']!['valueType'], 'boolean');
    expect(columns['address']!['valueType'], 'json');
    expect(columns['address']!['declaredType'], 'Object<Address>');
    expect(columns['age']!['valueType'], 'integer');
    expect(columns['birthday']!['valueType'], 'dateTime');
    expect(columns['mood']!['declaredType'],
        'Byte enum(calm=0, happy=1, angry=2)');
    expect(columns['score']!['valueType'], 'real');
    expect(columns['tags']!['valueType'], 'json');

    final note = ok(await call(Methods.schemaTable, {'table': 'Note'}));
    expect(
        (((note['schema']! as Map)['columns']! as List).first as Map)['name'],
        'noteId');
  });

  test('pages objects with converted values', () async {
    final page = await rows({'table': 'Person', 'pageSize': 10, 'page': 2});
    expect(page['total'], 30);
    final first = (page['rows']! as List).first as Map;
    expect(first['key'], {'id': 21});
    final columns = [
      for (final c in page['columns']! as List) (c as Map)['name'],
    ];
    final values = Map.fromIterables(columns, first['values']! as List);
    expect(values['name'], 'P20');
    expect(values['age'], 40);
    expect(values['birthday'],
        {r'$type': 'dateTime', 'value': '2020-01-01T00:00:00.000Z'});
    expect(values['address'], {
      r'$type': 'json',
      'value': {'city': 'Chennai', 'since': null, 'zip': '60020'},
    });
    expect(values['tags'], {
      r'$type': 'json',
      'value': ['t2'],
    });
    expect(values['mood'], 2);
    expect((page['rows']! as List), hasLength(10));
  });

  test('filters natively where Isar can express them', () async {
    Future<int> total(List<Map<String, Object?>> filters) async =>
        (await rows({'table': 'Person', 'filters': filters}))['total']! as int;

    expect(
        await total([
          {'column': 'age', 'operator': 'isNull'},
        ]),
        6);
    expect(
        await total([
          {'column': 'age', 'operator': 'greaterOrEqual', 'value': '45'},
        ]),
        4);
    // Isar orders null below numbers; nulls must not match "less than".
    expect(
        await total([
          {'column': 'age', 'operator': 'lessThan', 'value': 22},
        ]),
        2);
    expect(
        await total([
          {'column': 'age', 'operator': 'notEquals', 'value': 20},
        ]),
        29);
    expect(
        await total([
          {'column': 'name', 'operator': 'startsWith', 'value': 'p2'},
        ]),
        11);
    expect(
        await total([
          {'column': 'name', 'operator': 'contains', 'value': '1'},
        ]),
        12);
    expect(
        await total([
          {'column': 'name', 'operator': 'equals', 'value': 'P3'},
        ]),
        1);
    expect(
        await total([
          {'column': 'name', 'operator': 'notEquals', 'value': 'P3'},
        ]),
        29);
    expect(
        await total([
          {'column': 'active', 'operator': 'equals', 'value': 'true'},
          {'column': 'address', 'operator': 'isNotNull'},
        ]),
        15);
    expect(
        await total([
          {'column': 'id', 'operator': 'lessOrEqual', 'value': 3},
        ]),
        3);

    final binding = IsarCollectionBinding(isar, PersonSchema);
    final native = await binding.query(const RowsQuery(
      table: 'Person',
      pageSize: 2,
      filters: [RowFilter(column: 'age', operator: FilterOperator.isNull)],
      sort: [RowSort(column: 'name', direction: SortDirection.desc)],
    ));
    expect(native, isNotNull);
    expect(native!.total, 6);
    expect(native.documents.map((d) => d['name']), ['P9', 'P4']);
  });

  test('falls back to the generic engine for the rest', () async {
    final binding = IsarCollectionBinding(isar, PersonSchema);
    for (final query in [
      const RowsQuery(table: 'Person', search: 'chennai'),
      const RowsQuery(table: 'Person', filters: [
        RowFilter(
            column: 'score', operator: FilterOperator.greaterThan, value: 40),
      ]),
      const RowsQuery(table: 'Person', filters: [
        RowFilter(
            column: 'tags', operator: FilterOperator.contains, value: 't'),
      ]),
      const RowsQuery(table: 'Person', sort: [RowSort(column: 'tags')]),
    ]) {
      expect(await binding.query(query), isNull);
    }

    expect((await rows({'table': 'Person', 'search': 'chennai'}))['total'], 15);
    expect(
        (await rows({
          'table': 'Person',
          'filters': [
            {'column': 'score', 'operator': 'greaterThan', 'value': 40},
          ],
        }))['total'],
        3);
    expect(
        (await rows({
          'table': 'Person',
          'filters': [
            {'column': 'tags', 'operator': 'contains', 'value': 't1'},
          ],
        }))['total'],
        10);
    final count = ok(await call(Methods.rowsCount, {
      'table': 'Person',
      'filters': [
        {'column': 'age', 'operator': 'isNotNull'},
      ],
    }));
    expect(count['count'], 24);
    expect(
      errorCode(await call(Methods.rowsQuery, {
        'table': 'Person',
        'filters': [
          {'column': 'nope', 'operator': 'isNull'},
        ],
      })),
      'COLUMN_NOT_FOUND',
    );
  });

  test('sorts', () async {
    final byAge = await rows({
      'table': 'Person',
      'pageSize': 3,
      'sort': [
        {'column': 'age', 'direction': 'desc'},
      ],
    });
    expect(keys(byAge), [
      {'id': 29},
      {'id': 28},
      {'id': 27},
    ]);
    final byId = await rows({
      'table': 'Person',
      'pageSize': 2,
      'sort': [
        {'column': 'id', 'direction': 'desc'},
      ],
    });
    expect(keys(byId), [
      {'id': 30},
      {'id': 29},
    ]);
    // Ties on `active` keep id order.
    final byActive = await rows({
      'table': 'Person',
      'pageSize': 3,
      'sort': [
        {'column': 'active', 'direction': 'asc'},
      ],
    });
    expect(keys(byActive), [
      {'id': 2},
      {'id': 4},
      {'id': 6},
    ]);
    final byTags = await rows({
      'table': 'Person',
      'pageSize': 1,
      'sort': [
        {'column': 'tags', 'direction': 'desc'},
      ],
    });
    expect(keys(byTags), [
      {'id': 3},
    ]);
  });

  test('inserts objects', () async {
    final inserted = ok(await call(Methods.rowInsert, {
      'table': 'Person',
      'values': {
        'name': 'New',
        'age': '7',
        'birthday': {r'$type': 'dateTime', 'value': '1999-12-31T00:00:00Z'},
        'tags': {
          r'$type': 'json',
          'value': ['a', 'b'],
        },
        'address': {
          r'$type': 'json',
          'value': {'city': 'Madurai'},
        },
      },
    }));
    expect(inserted['insertedKey'], {'id': 31});
    final p = (await isar.persons.get(31))!;
    expect(p.name, 'New');
    expect(p.age, 7);
    expect(p.birthday!.toUtc(), DateTime.utc(1999, 12, 31));
    expect(p.tags, ['a', 'b']);
    expect(p.address!.city, 'Madurai');
    expect(p.active, isFalse, reason: 'omitted fields take Isar defaults');

    final explicit = ok(await call(Methods.rowInsert, {
      'table': 'Person',
      'values': {'id': 100, 'name': 'Hundred'},
    }));
    expect(explicit['insertedKey'], {'id': 100});
    expect((await isar.persons.get(100))!.name, 'Hundred');
    final next = ok(await call(Methods.rowInsert, {
      'table': 'Person',
      'values': {'name': 'After'},
    }));
    expect(next['insertedKey'], {'id': 101});

    expect(
      errorCode(await call(Methods.rowInsert, {
        'table': 'Person',
        'values': {'id': 1, 'name': 'dup'},
      })),
      'INVALID_REQUEST',
    );
    expect(
      errorCode(await call(Methods.rowInsert, {
        'table': 'Person',
        'values': {'name': 'x', 'unknown': 1},
      })),
      'COLUMN_NOT_FOUND',
    );
    expect(
      errorCode(await call(Methods.rowInsert, {
        'table': 'Person',
        'values': {'name': 'x', 'age': 'old'},
      })),
      'INVALID_REQUEST',
    );
    // Unique index violation surfaces as a failed transaction.
    expect(
      errorCode(await call(Methods.rowInsert, {
        'table': 'Note',
        'values': {'title': 'n1', 'author': 'a'},
      })),
      'TRANSACTION_FAILED',
    );
    expect(await isar.notes.count(), 3);
  });

  test('updates, deletes and clears', () async {
    ok(await call(Methods.rowUpdate, {
      'table': 'Person',
      'key': {'id': 1},
      'values': {
        'name': 'Renamed',
        'age': null,
        'address': {
          r'$type': 'json',
          'value': {'city': 'Kochi', 'zip': '682001'},
        },
      },
    }));
    final p = (await isar.persons.get(1))!;
    expect(p.name, 'Renamed');
    expect(p.age, isNull);
    expect(p.address!.city, 'Kochi');
    expect(p.tags, ['t0'], reason: 'untouched fields are kept');
    expect(p.birthday!.toUtc(), DateTime.utc(2000));
    // The index follows the update.
    expect(await isar.persons.filter().nameEqualTo('Renamed').count(), 1);

    expect(
      errorCode(await call(Methods.rowUpdate, {
        'table': 'Person',
        'key': {'id': 999},
        'values': {'name': 'x'},
      })),
      'ROW_NOT_FOUND',
    );
    expect(
      errorCode(await call(Methods.rowUpdate, {
        'table': 'Person',
        'key': {'id': 1},
        'values': {'id': 5},
      })),
      'UNSUPPORTED_OPERATION',
    );

    ok(await call(Methods.rowUpdate, {
      'table': 'Note',
      'key': {'noteId': 2},
      'values': {'author': 'b'},
    }));
    expect((await isar.notes.get(2))!.author, 'b');

    ok(await call(Methods.rowDelete, {
      'table': 'Person',
      'key': {'id': 2},
    }));
    expect(await isar.persons.get(2), isNull);
    expect(
      errorCode(await call(Methods.rowDelete, {
        'table': 'Person',
        'key': {'id': 2},
      })),
      'ROW_NOT_FOUND',
    );

    final cleared = ok(await call(Methods.tableClear, {'table': 'Person'}));
    expect(cleared['affectedRows'], 29);
    expect(await isar.persons.count(), 0);
  });

  test('reads full values', () async {
    final chunk = ok(await call(Methods.valueRead, {
      'table': 'Person',
      'key': {'id': 1},
      'column': 'address',
    }));
    expect(chunk['totalBytes'], greaterThan(10));
  });
}

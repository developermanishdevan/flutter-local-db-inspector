import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_sembast/flutter_db_inspector_sembast.dart';
import 'package:sembast/blob.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sembast/timestamp.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late InspectorRouter router;
  final people = intMapStoreFactory.store('people');
  final users = stringMapStoreFactory.store('users');
  final tokens = StoreRef<String, String>('tokens');
  final counters = StoreRef<int, int>('counters');
  var dbCounter = 0;

  setUp(() async {
    db = await databaseFactoryMemory.openDatabase('test_${dbCounter++}.db');
    await db.transaction((txn) async {
      for (var i = 0; i < 30; i++) {
        await people.add(txn, {
          'name': 'P$i',
          'age': 20 + i,
          if (i.isEven) 'city': 'Chennai',
          'tags': ['t${i % 3}'],
        });
      }
      await users.record('u1').put(txn, {
        'email': 'asha@example.com',
        'joined': Timestamp.fromDateTime(DateTime.utc(2024, 1, 2)),
        'avatar': Blob(Uint8List.fromList([1, 2, 3])),
        'profile': {'theme': 'dark'},
      });
      await users.record('u2').put(txn, {'email': 'ravi@example.com'});
      await tokens.record('a').put(txn, 'alpha');
      await tokens.record('b').put(txn, 'beta');
      await counters.record(1).put(txn, 10);
    });
    final registry = DbRegistry()
      ..register('app', SembastAdapter(db, stores: ['empty']));
    router = InspectorRouter(
      registry: registry,
      config: () => const InspectorConfig(mode: InspectorMode.fullAccess),
    );
  });

  tearDown(() => db.close());

  Future<Map<String, Object?>> call(String method,
      [Map<String, Object?> p = const {}]) async {
    return jsonDecode(await router.handleRaw(jsonEncode({
      'method': method,
      'params': {'databaseId': 'app', ...p},
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

  List<Object?> column(Map<String, Object?> page, int index) => [
        for (final r in page['rows']! as List)
          ((r as Map)['values']! as List)[index],
      ];

  test('describes the database and discovers stores', () async {
    final list = ok(await call(Methods.databaseList));
    final app = (list['databases']! as List).single as Map;
    expect(app['type'], 'sembast');
    expect(app['dataModel'], 'document');

    final schema = ok(await call(Methods.schemaList));
    final entities = {
      for (final e in schema['entities']! as List) (e as Map)['name']: e,
    };
    expect(entities.keys,
        ['counters', 'empty', 'people', 'tokens', 'users']); // sorted
    expect(entities['people']!['kind'], 'collection');
    expect(entities['people']!['rowCount'], 30);
    expect(entities['empty']!['rowCount'], 0);

    final info = ok(await call(Methods.databaseInfo));
    expect(jsonEncode(info), contains('schemaVersion'));
  });

  test('infers fields of map and scalar stores', () async {
    Future<List<Object?>> columns(String table) async {
      final r = ok(await call(Methods.schemaTable, {'table': table}));
      final schema = r['schema']! as Map;
      expect(schema['kind'], 'collection');
      return [for (final c in schema['columns']! as List) (c as Map)['name']];
    }

    expect(await columns('people'), ['_key', 'name', 'age', 'city', 'tags']);
    expect(await columns('users'),
        ['_key', 'email', 'joined', 'avatar', 'profile']);
    expect(await columns('tokens'), ['_key', '_value']);
  });

  test('pages in key order', () async {
    final page = await rows({'table': 'people', 'pageSize': 10, 'page': 2});
    expect(page['total'], 30);
    final first = (page['rows']! as List).first as Map;
    expect(first['key'], {'_key': 21});
    expect(first['values'], [
      21,
      'P20',
      40,
      'Chennai',
      {
        r'$type': 'json',
        'value': ['t2'],
      },
    ]);
    final last = await rows({'table': 'people', 'pageSize': 25, 'page': 1});
    expect((last['rows']! as List), hasLength(5));
  });

  test('converts Sembast timestamps and blobs', () async {
    final page = await rows({'table': 'users'});
    final values = ((page['rows']! as List).first as Map)['values']! as List;
    expect(values[0], 'u1');
    expect((values[2] as Map)[r'$type'], 'dateTime');
    expect((values[3] as Map)[r'$type'], 'blob');
  });

  test('native filters', () async {
    Future<int> total(List<Map<String, Object?>> filters) async =>
        (await rows({'table': 'people', 'filters': filters}))['total']! as int;

    expect(
        await total([
          {'column': 'city', 'operator': 'isNull'},
        ]),
        15);
    expect(
        await total([
          {'column': 'city', 'operator': 'isNotNull'},
        ]),
        15);
    // Text from the UI compares numerically with stored ints.
    expect(
        await total([
          {'column': 'age', 'operator': 'equals', 'value': '25'},
        ]),
        1);
    expect(
        await total([
          {'column': 'age', 'operator': 'greaterOrEqual', 'value': 45},
        ]),
        5);
    expect(
        await total([
          {'column': 'age', 'operator': 'lessThan', 'value': '22'},
          {'column': 'city', 'operator': 'isNotNull'},
        ]),
        1);
    expect(
        await total([
          {'column': 'name', 'operator': 'notEquals', 'value': 'P3'},
        ]),
        29);
    // Case-insensitive text matching; regex characters are literal.
    expect(
        await total([
          {'column': 'name', 'operator': 'startsWith', 'value': 'p2'},
        ]),
        11);
    expect(
        await total([
          {'column': 'name', 'operator': 'endsWith', 'value': '9'},
        ]),
        3);
    expect(
        await total([
          {'column': 'name', 'operator': 'contains', 'value': '.'},
        ]),
        0);
    // Non-string values match on their text form.
    expect(
        await total([
          {'column': 'age', 'operator': 'contains', 'value': '4'},
        ]),
        12);
    expect(
        await total([
          {'column': 'tags', 'operator': 'contains', 'value': 't1'},
        ]),
        10);
    expect(
        await total([
          {'column': '_key', 'operator': 'lessOrEqual', 'value': 3},
        ]),
        3);

    final count = ok(await call(Methods.rowsCount, {
      'table': 'people',
      'filters': [
        {'column': 'city', 'operator': 'equals', 'value': 'Chennai'},
      ],
    }));
    expect(count['count'], 15);
  });

  test('the native path is used for filters and sorting', () async {
    final collection = SembastStoreCollection(db, 'people');
    final page = await collection.query(const RowsQuery(
      table: 'people',
      pageSize: 2,
      filters: [
        RowFilter(column: 'city', operator: FilterOperator.isNull),
      ],
      sort: [RowSort(column: 'age', direction: SortDirection.desc)],
    ));
    expect(page, isNotNull);
    expect(page!.total, 15);
    expect(page.documents.map((d) => d['name']), ['P29', 'P27']);
    // Search stays in the generic engine so masked columns are honoured.
    expect(
        await collection.query(const RowsQuery(table: 'people', search: 'P1')),
        isNull);
  });

  test('sorts and searches', () async {
    final sorted = await rows({
      'table': 'people',
      'pageSize': 3,
      'sort': [
        {'column': 'city', 'direction': 'asc'},
        {'column': 'age', 'direction': 'desc'},
      ],
    });
    expect(column(sorted, 1), ['P29', 'P27', 'P25']);

    final search = await rows({'table': 'users', 'search': 'RAVI'});
    expect(search['total'], 1);

    final scalars = await rows({
      'table': 'tokens',
      'filters': [
        {'column': '_value', 'operator': 'startsWith', 'value': 'al'},
      ],
    });
    expect(scalars['total'], 1);
    expect(column(scalars, 0), ['a']);

    final keys = await rows({
      'table': 'users',
      'sort': [
        {'column': '_key', 'direction': 'desc'},
      ],
    });
    expect(column(keys, 0), ['u2', 'u1']);
  });

  test('insert, update, delete and clear in an int keyed store', () async {
    final inserted = ok(await call(Methods.rowInsert, {
      'table': 'people',
      'values': {
        'name': 'New',
        'age': 1,
        'seen': {r'$type': 'dateTime', 'value': '2024-05-01T00:00:00.000Z'},
      },
    }));
    expect(inserted['insertedKey'], {'_key': 31});
    final stored = (await people.record(31).get(db))!;
    expect(stored['seen'], isA<Timestamp>());

    ok(await call(Methods.rowUpdate, {
      'table': 'people',
      'key': {'_key': 31},
      'values': {'name': 'Renamed', 'city': null},
    }));
    expect(await people.record(31).get(db), {
      'name': 'Renamed',
      'age': 1,
      'seen': stored['seen'],
      'city': null,
    });

    expect(
      errorCode(await call(Methods.rowUpdate, {
        'table': 'people',
        'key': {'_key': 999},
        'values': {'name': 'x'},
      })),
      'ROW_NOT_FOUND',
    );
    expect(
      errorCode(await call(Methods.rowInsert, {
        'table': 'people',
        'values': {'_key': 1, 'name': 'dup'},
      })),
      'INVALID_REQUEST',
    );

    ok(await call(Methods.rowDelete, {
      'table': 'people',
      'key': {'_key': 31},
    }));
    expect(await people.record(31).get(db), isNull);
    expect(
      errorCode(await call(Methods.rowDelete, {
        'table': 'people',
        'key': {'_key': 31},
      })),
      'ROW_NOT_FOUND',
    );

    final cleared = ok(await call(Methods.tableClear, {'table': 'people'}));
    expect(cleared['affectedRows'], 30);
    expect(await people.count(db), 0);
  });

  test('insert, update and delete in a String keyed store', () async {
    final explicit = ok(await call(Methods.rowInsert, {
      'table': 'users',
      'values': {'_key': 'u9', 'email': 'new@example.com'},
    }));
    expect(explicit['insertedKey'], {'_key': 'u9'});
    expect(await users.record('u9').get(db), {'email': 'new@example.com'});

    // Without a key, a String key is generated like the app's typed store.
    final generated = ok(await call(Methods.rowInsert, {
      'table': 'users',
      'values': {'email': 'gen@example.com'},
    }));
    final key = (generated['insertedKey']! as Map)['_key'];
    expect(key, isA<String>());
    expect(await users.record(key! as String).get(db),
        {'email': 'gen@example.com'});

    ok(await call(Methods.rowUpdate, {
      'table': 'users',
      'key': {'_key': 'u1'},
      'values': {
        'profile': {
          r'$type': 'json',
          'value': {'theme': 'light'},
        },
      },
    }));
    final u1 = (await users.record('u1').get(db))!;
    expect(u1['profile'], {'theme': 'light'});
    expect(u1['avatar'], isA<Blob>(), reason: 'untouched fields keep types');

    ok(await call(Methods.rowDelete, {
      'table': 'users',
      'key': {'_key': 'u2'},
    }));
    expect(await users.record('u2').exists(db), isFalse);
  });

  test('edits records that are not maps', () async {
    final page = await rows({'table': 'tokens'});
    expect(((page['rows']! as List).first as Map)['values'], ['a', 'alpha']);

    ok(await call(Methods.rowUpdate, {
      'table': 'tokens',
      'key': {'_key': 'b'},
      'values': {'_value': 'bravo'},
    }));
    expect(await tokens.record('b').get(db), 'bravo');
    expect(
      errorCode(await call(Methods.rowUpdate, {
        'table': 'tokens',
        'key': {'_key': 'b'},
        'values': {'other': 1},
      })),
      'INVALID_REQUEST',
    );

    final inserted = ok(await call(Methods.rowInsert, {
      'table': 'counters',
      'values': {'_value': 5},
    }));
    expect(inserted['insertedKey'], {'_key': 2});
    expect(await counters.record(2).get(db), 5);

    final generated = ok(await call(Methods.rowInsert, {
      'table': 'tokens',
      'values': {'_value': 'gamma'},
    }));
    expect((generated['insertedKey']! as Map)['_key'], isA<String>());
  });

  test('reads full values', () async {
    final chunk = ok(await call(Methods.valueRead, {
      'table': 'users',
      'key': {'_key': 'u1'},
      'column': 'email',
    }));
    expect(jsonEncode(chunk), contains('totalBytes'));
    expect(chunk['totalBytes'], 'asha@example.com'.length);
  });

  test('unknown stores are reported', () async {
    expect(errorCode(await call(Methods.rowsQuery, {'table': 'nope'})),
        'TABLE_NOT_FOUND');
  });
}

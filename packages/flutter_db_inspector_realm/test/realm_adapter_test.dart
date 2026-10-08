import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_realm/flutter_db_inspector_realm.dart';
import 'package:realm_dart/realm.dart';
import 'package:test/test.dart';

import 'models.dart';

final _epoch = DateTime.utc(2024);

/// Seeds 100 people (every 10th without email, odd ids inactive, person 7
/// named "Zoë", 1-3 with an address, each befriending the previous one),
/// 3 notes keyed by ObjectId and 5 log entries without a primary key.
void seed(Realm realm) {
  realm.write(() {
    Person? previous;
    for (var i = 1; i <= 100; i++) {
      previous = realm.add(Person(
        i,
        i == 7 ? 'Zoë' : 'User $i',
        i.isEven,
        i * 1.5,
        email: i % 10 == 0 ? null : 'user$i@example.com',
        createdAt: _epoch.add(Duration(days: i)),
        avatar: i == 1 ? Uint8List.fromList([1, 2, 3]) : null,
        tags: ['t$i', 'all'],
        address: i <= 3 ? Address('City $i', zip: '6000$i') : null,
        bestFriend: previous,
        counters: {'visits': i},
      ));
    }
    for (var i = 1; i <= 3; i++) {
      realm.add(Note(
        ObjectId(),
        'Note $i',
        amount: Decimal128.parse('$i.25'),
        token: Uuid.v4(),
        extra: RealmValue.from(i == 1 ? 'mixed' : i),
      ));
    }
    for (var i = 1; i <= 5; i++) {
      realm.add(LogEntry('Log $i', i % 3));
    }
  });
}

/// A collection without native queries, so [DocumentAdapter] evaluates the
/// same request in memory: used to check native RQL results against it.
class _InMemoryRealmCollection extends RealmCollection {
  _InMemoryRealmCollection(super.realm, super.schema);

  @override
  Future<DocumentPage?> query(RowsQuery query) async => null;
}

void main() {
  late Directory dir;
  late Realm realm;
  late InspectorRouter router;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('realm_inspector_test');
    realm = Realm(Configuration.local(
      [Person.schema, Address.schema, Note.schema, LogEntry.schema],
      path: '${dir.path}/test.realm',
    ));
    seed(realm);
    const config = InspectorConfig(mode: InspectorMode.fullAccess);
    final registry = DbRegistry()
      ..register('main', RealmAdapter(realm))
      ..register(
        'memory',
        DocumentAdapter(
          type: 'realm',
          collections: () => [
            for (final s in realm.schema)
              if (s.baseType == ObjectType.realmObject)
                _InMemoryRealmCollection(realm, s),
          ],
        ),
      );
    router = InspectorRouter(registry: registry, config: () => config);
  });

  tearDown(() {
    realm.close();
    dir.deleteSync(recursive: true);
  });

  /// Sends a request exactly as a client would (JSON in, JSON out).
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
    String databaseId = 'main',
  ]) async {
    final raw = await router.handleRaw(jsonEncode({
      'version': 1,
      'requestId': 'r1',
      'method': method,
      'params': {'databaseId': databaseId, ...params},
    }));
    return jsonDecode(raw) as Map<String, Object?>;
  }

  Map<String, Object?> ok(Map<String, Object?> response) {
    expect(response['success'], isTrue, reason: '$response');
    return response['result']! as Map<String, Object?>;
  }

  String errorCode(Map<String, Object?> response) {
    expect(response['success'], isFalse, reason: '$response');
    return (response['error']! as Map)['code'] as String;
  }

  /// Rows of a `rows.query` result as column → value maps.
  List<Map<String, Object?>> rowsOf(Map<String, Object?> page) {
    final columns = [
      for (final c in page['columns']! as List) (c as Map)['name'] as String,
    ];
    return [
      for (final r in page['rows']! as List)
        {
          for (var i = 0; i < columns.length; i++)
            columns[i]: ((r as Map)['values']! as List)[i],
        },
    ];
  }

  Future<Map<String, Object?>> rows(
    String table, [
    Map<String, Object?> params = const {},
    String databaseId = 'main',
  ]) async =>
      ok(await call(
          Methods.rowsQuery, {'table': table, ...params}, databaseId));

  group('discovery', () {
    test('database.list reports a document realm database', () async {
      final dbs = ok(await call(Methods.databaseList))['databases']! as List;
      final main = dbs.firstWhere((d) => (d as Map)['id'] == 'main') as Map;
      expect(main['type'], 'realm');
      expect(main['dataModel'], 'document');
    });

    test('schema.list shows top-level classes only (no embedded)', () async {
      final schema = ok(await call(Methods.schemaList));
      final entities = [
        for (final e in schema['entities']! as List) e as Map,
      ];
      expect(entities.map((e) => e['name']), ['LogEntry', 'Note', 'Person']);
      expect(entities.map((e) => e['kind']).toSet(), {'collection'});
      expect(entities.map((e) => e['rowCount']), [5, 3, 100]);
      expect(entities.map((e) => e['readOnly']), [true, false, false]);
      final indexes = [for (final i in schema['indexes']! as List) i as Map];
      expect(
        indexes.map((i) => i['name']),
        containsAll(['Person.id', 'Person.name', 'Note.id']),
      );
    });

    test('schema.table maps Realm property types', () async {
      final result =
          ok(await call(Methods.schemaTable, {'table': 'Person'}))['schema']!
              as Map;
      expect(result['kind'], 'collection');
      expect(result['rowKey'], 'key');
      final columns = {
        for (final c in result['columns']! as List)
          (c as Map)['name']: (c['valueType'], c['declaredType']),
      };
      expect(columns, {
        'id': ('integer', 'int'),
        'name': ('text', 'string'),
        'email': ('text', 'string?'),
        'isActive': ('boolean', 'bool'),
        'score': ('real', 'double'),
        'createdAt': ('dateTime', 'date?'),
        'avatar': ('blob', 'data?'),
        'tags': ('json', 'list<string>'),
        'address': ('json', 'link<Address>?'),
        'bestFriend': ('json', 'link<Person>?'),
        'counters': ('json', 'map<string, int>'),
      });
      final id = (result['columns']! as List).first as Map;
      expect(id['primaryKeyPosition'], 1);

      final note =
          ok(await call(Methods.schemaTable, {'table': 'Note'}))['schema']!
              as Map;
      expect({
        for (final c in note['columns']! as List)
          (c as Map)['name']: c['valueType'],
      }, {
        'id': 'text',
        'text': 'text',
        'amount': 'real',
        'token': 'text',
        'extra': 'unknown',
      });

      final log =
          ok(await call(Methods.schemaTable, {'table': 'LogEntry'}))['schema']!
              as Map;
      expect(log['rowKey'], 'none');
      expect(
        [for (final c in log['columns']! as List) (c as Map)['name']],
        ['message', 'level'],
      );
    });

    test('unknown classes are TABLE_NOT_FOUND', () async {
      expect(
        errorCode(await call(Methods.rowsQuery, {'table': 'Nope'})),
        'TABLE_NOT_FOUND',
      );
    });
  });

  group('reading', () {
    test('pages lazily through results', () async {
      final page = await rows('Person', {'page': 2, 'pageSize': 10});
      expect(page['total'], 100);
      final people = rowsOf(page);
      expect(people.map((p) => p['id']), [for (var i = 21; i <= 30; i++) i]);
      final keys = [for (final r in page['rows']! as List) (r as Map)['key']];
      expect(keys.first, {'id': 21});

      final last = rowsOf(await rows('Person', {'page': 9, 'pageSize': 15}));
      expect(last.map((p) => p['id']),
          [for (var i = 136; i <= 150; i++) i].where((i) => i <= 100));
      expect(rowsOf(await rows('Person', {'page': 50})), isEmpty);
    });

    test('converts values, links, embedded objects and collections', () async {
      final people = rowsOf(await rows('Person', {'pageSize': 3}));
      final first = people[0], second = people[1];
      expect(first['name'], 'User 1');
      expect(first['email'], 'user1@example.com');
      expect(first['isActive'], false);
      expect(first['score'], 1.5);
      expect(first['createdAt'], {
        r'$type': 'dateTime',
        'value': _epoch.add(const Duration(days: 1)).toIso8601String(),
      });
      expect((first['avatar']! as Map)[r'$type'], 'blob');
      expect(first['tags'], {
        r'$type': 'json',
        'value': ['t1', 'all'],
      });
      expect(first['address'], {
        r'$type': 'json',
        'value': {'city': 'City 1', 'zip': '60001'},
      });
      expect(first['bestFriend'], isNull);
      // Links are shown as the target's primary key.
      expect(second['bestFriend'], 1);
      expect(first['counters'], {
        r'$type': 'json',
        'value': {'visits': 1},
      });

      final notes = rowsOf(await rows('Note'));
      expect(notes.map((n) => n['text']), ['Note 1', 'Note 2', 'Note 3']);
      expect(notes.first['id'], matches(RegExp(r'^[0-9a-f]{24}$')));
      expect(notes.first['token'], matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(notes.first['amount'], 1.25);
      expect(notes.map((n) => n['extra']), ['mixed', 2, 3]);
    });

    test('objects without a primary key are listed but not addressable',
        () async {
      final page = await rows('LogEntry');
      expect(page['total'], 5);
      expect(rowsOf(page).map((l) => l['message']),
          ['Log 1', 'Log 2', 'Log 3', 'Log 4', 'Log 5']);
      expect(
        [for (final r in page['rows']! as List) (r as Map)['key']],
        everyElement(isNull),
      );
      final filtered = await rows('LogEntry', {
        'filters': [
          {'column': 'level', 'operator': 'equals', 'value': 1},
        ],
      });
      expect(rowsOf(filtered).map((l) => l['message']), ['Log 1', 'Log 4']);
    });

    test('value.read reads a full value by primary key', () async {
      final chunk = ok(await call(Methods.valueRead, {
        'table': 'Person',
        'key': {'id': 7},
        'column': 'name',
      }));
      expect(chunk['isText'], isTrue);
      expect(chunk['totalBytes'], utf8.encode('Zoë').length);
    });

    test('database.info reports the realm file', () async {
      final info = ok(await call(Methods.databaseInfo));
      expect(jsonEncode(info), contains('test.realm'));
    });
  });

  group('native queries', () {
    RealmCollection person() => RealmAdapter.collectionsOf(realm)
        .singleWhere((c) => c.name == 'Person');

    Future<DocumentPage?> native(
      List<RowFilter> filters, [
      List<RowSort> sort = const [],
    ]) =>
        person().query(RowsQuery(
          table: 'Person',
          filters: filters,
          sort: sort,
          pageSize: 200,
        ));

    test('supported filters and sorts run as RQL', () async {
      for (final f in [
        const RowFilter(
            column: 'name', operator: FilterOperator.equals, value: 'Zoë'),
        const RowFilter(
            column: 'name', operator: FilterOperator.contains, value: 'USER 1'),
        const RowFilter(
            column: 'email',
            operator: FilterOperator.startsWith,
            value: 'user9'),
        const RowFilter(
            column: 'email',
            operator: FilterOperator.endsWith,
            value: '0@EXAMPLE.COM'),
        const RowFilter(
            column: 'id', operator: FilterOperator.greaterThan, value: 95),
        const RowFilter(
            column: 'score', operator: FilterOperator.lessOrEqual, value: '3'),
        const RowFilter(
            column: 'isActive', operator: FilterOperator.equals, value: 'TRUE'),
        const RowFilter(column: 'email', operator: FilterOperator.isNull),
        const RowFilter(column: 'name', operator: FilterOperator.isNull),
      ]) {
        expect(await native([f]), isNotNull, reason: f.toJson().toString());
      }
      final sorted = await native(
        [],
        [
          const RowSort(column: 'isActive', direction: SortDirection.desc),
          const RowSort(column: 'id', direction: SortDirection.desc),
        ],
      );
      expect(sorted!.documents.take(2).map((d) => d['id']), [100, 98]);
    });

    test('unsupported filters fall back to the in-memory engine', () async {
      for (final f in [
        // Numeric-looking text compares numerically in memory.
        const RowFilter(
            column: 'name', operator: FilterOperator.greaterThan, value: 'U'),
        const RowFilter(
            column: 'name', operator: FilterOperator.contains, value: 'oË'),
        const RowFilter(
            column: 'id', operator: FilterOperator.equals, value: 2.5),
        const RowFilter(
            column: 'tags', operator: FilterOperator.contains, value: 't1'),
        const RowFilter(
            column: 'createdAt',
            operator: FilterOperator.greaterThan,
            value: '2024'),
      ]) {
        expect(await native([f]), isNull, reason: f.toJson().toString());
      }
      expect(
        await native([], [const RowSort(column: 'name')]),
        isNull,
        reason: 'string collation differs from the in-memory order',
      );
    });

    final cases = <String, Map<String, Object?>>{
      'equals text': {
        'filters': [
          {'column': 'name', 'operator': 'equals', 'value': 'User 42'},
        ],
      },
      'contains is case-insensitive': {
        'filters': [
          {'column': 'name', 'operator': 'contains', 'value': 'USER 1'},
        ],
      },
      'startsWith/endsWith': {
        'filters': [
          {'column': 'email', 'operator': 'startsWith', 'value': 'USER'},
          {'column': 'email', 'operator': 'endsWith', 'value': '5@example.com'},
        ],
      },
      'notEquals keeps nulls': {
        'filters': [
          {
            'column': 'email',
            'operator': 'notEquals',
            'value': 'user1@example.com',
          },
        ],
      },
      'numeric range + sort desc': {
        'filters': [
          {'column': 'id', 'operator': 'greaterOrEqual', 'value': 40},
          {'column': 'score', 'operator': 'lessThan', 'value': '75'},
        ],
        'sort': [
          {'column': 'score', 'direction': 'desc'},
        ],
      },
      'bool + null checks': {
        'filters': [
          {'column': 'isActive', 'operator': 'equals', 'value': true},
          {'column': 'email', 'operator': 'isNull'},
        ],
      },
      'sort by bool then date': {
        'sort': [
          {'column': 'isActive'},
          {'column': 'createdAt', 'direction': 'desc'},
        ],
      },
      'search stays in memory': {'search': 'zoë'},
    };
    for (final MapEntry(key: name, value: params) in cases.entries) {
      test('native matches in-memory: $name', () async {
        final query = {...params, 'pageSize': 200};
        final fast = await rows('Person', query);
        final slow = await rows('Person', query, 'memory');
        expect(rowsOf(fast), rowsOf(slow));
        expect(fast['total'], slow['total']);
        expect(fast['total'], greaterThan(0));
      });
    }

    test('paging applies to native results', () async {
      final page = await rows('Person', {
        'filters': [
          {'column': 'isActive', 'operator': 'equals', 'value': false},
        ],
        'sort': [
          {'column': 'id', 'direction': 'desc'},
        ],
        'page': 1,
        'pageSize': 5,
      });
      expect(page['total'], 50);
      expect(rowsOf(page).map((p) => p['id']), [89, 87, 85, 83, 81]);
      final count = ok(await call(Methods.rowsCount, {
        'table': 'Person',
        'filters': [
          {'column': 'name', 'operator': 'contains', 'value': 'zo'},
        ],
      }));
      expect(count['count'], 1);
    });
  });

  group('writing', () {
    test('update sets primitive properties', () async {
      ok(await call(Methods.rowUpdate, {
        'table': 'Person',
        'key': {'id': 5},
        'values': {
          'name': 'Renamed',
          'email': null,
          'score': 7,
          'isActive': true,
          'createdAt': {r'$type': 'dateTime', 'value': '2030-01-02T00:00:00Z'},
        },
      }));
      final p = realm.find<Person>(5)!;
      expect(p.name, 'Renamed');
      expect(p.email, isNull);
      expect(p.score, 7.0);
      expect(p.isActive, isTrue);
      expect(p.createdAt, DateTime.utc(2030, 1, 2));
    });

    test('updates by stringified ObjectId keys', () async {
      final note = realm.all<Note>().first;
      ok(await call(Methods.rowUpdate, {
        'table': 'Note',
        'key': {'id': note.id.toString()},
        'values': {'text': 'Edited', 'amount': '9.75', 'extra': 'x'},
      }));
      expect(note.text, 'Edited');
      expect(note.amount, Decimal128.parse('9.75'));
      expect(note.extra.value, 'x');
    });

    test('rejects edits to links/collections and invalid values', () async {
      for (final values in [
        {'tags': <String>[]},
        {'bestFriend': 3},
        {'address': null},
      ]) {
        expect(
          errorCode(await call(Methods.rowUpdate, {
            'table': 'Person',
            'key': {'id': 5},
            'values': values,
          })),
          'UNSUPPORTED_OPERATION',
        );
      }
      expect(
        errorCode(await call(Methods.rowUpdate, {
          'table': 'Person',
          'key': {'id': 5},
          'values': {'name': null},
        })),
        'INVALID_REQUEST',
      );
      expect(
        errorCode(await call(Methods.rowUpdate, {
          'table': 'Person',
          'key': {'id': 5},
          'values': {'score': 'abc'},
        })),
        'INVALID_REQUEST',
      );
      expect(
        errorCode(await call(Methods.rowUpdate, {
          'table': 'Person',
          'key': {'id': 5},
          'values': {'id': 6},
        })),
        'UNSUPPORTED_OPERATION',
      );
      expect(
        errorCode(await call(Methods.rowUpdate, {
          'table': 'Person',
          'key': {'id': 999},
          'values': {'name': 'x'},
        })),
        'ROW_NOT_FOUND',
      );
      expect(realm.find<Person>(5)!.name, 'User 5');
    });

    test('insert creates objects dynamically', () async {
      final inserted = ok(await call(Methods.rowInsert, {
        'table': 'Person',
        'values': {'id': 500, 'name': 'New', 'isActive': true, 'score': 1},
      }));
      expect(inserted['insertedKey'], {'id': 500});
      final p = realm.find<Person>(500)!;
      expect(p.name, 'New');
      expect(p.isActive, isTrue);
      expect(p.tags, isEmpty);
      expect(
        errorCode(await call(Methods.rowInsert, {
          'table': 'Person',
          'values': {'id': 500, 'name': 'Dup'},
        })),
        'INVALID_REQUEST',
      );

      // ObjectId keys are generated when omitted.
      final note = ok(await call(Methods.rowInsert, {
        'table': 'Note',
        'values': {'text': 'Fresh'},
      }));
      final id = (note['insertedKey']! as Map)['id']! as String;
      expect(realm.find<Note>(ObjectId.fromHexString(id))!.text, 'Fresh');
    });

    test('delete removes an object', () async {
      ok(await call(Methods.rowDelete, {
        'table': 'Person',
        'key': {'id': 10},
      }));
      expect(realm.find<Person>(10), isNull);
      expect(realm.all<Person>().length, 99);
      expect(
        errorCode(await call(Methods.rowDelete, {
          'table': 'Person',
          'key': {'id': 10},
        })),
        'ROW_NOT_FOUND',
      );
    });

    test('clear deletes every object of the class', () async {
      final result = ok(await call(Methods.tableClear, {'table': 'Note'}));
      expect(result['affectedRows'], 3);
      expect(realm.all<Note>(), isEmpty);
      expect(realm.all<Person>().length, 100);
    });

    test('classes without a primary key are read-only', () async {
      for (final (method, params) in [
        (
          Methods.rowInsert,
          {
            'values': {'message': 'x', 'level': 1}
          }
        ),
        (
          Methods.rowUpdate,
          {
            'key': {'message': 'Log 1'},
            'values': {'level': 9},
          }
        ),
        (
          Methods.rowDelete,
          {
            'key': {'message': 'Log 1'}
          }
        ),
        (Methods.tableClear, const <String, Object?>{}),
      ]) {
        expect(
          errorCode(await call(method, {'table': 'LogEntry', ...params})),
          'WRITE_NOT_ALLOWED',
          reason: method,
        );
      }
      expect(realm.all<LogEntry>().length, 5);
    });
  });
}

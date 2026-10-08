import 'dart:convert';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  late DbRegistry registry;
  late InspectorRouter router;
  late MemoryStore settings;
  late MemoryCollection people;

  setUp(() async {
    settings = MemoryStore('settings', {
      'theme': 'dark',
      'launches': 42,
      'onboarded': true,
      'profile': {
        'name': 'Asha',
        'tags': ['a', 'b']
      },
      'person': Person('Ravi', 31),
      7: null,
    });
    people = MemoryCollection('people');
    for (var i = 0; i < 30; i++) {
      await people.insert(
          {'name': 'P$i', 'age': 20 + i, if (i.isEven) 'city': 'Chennai'});
    }
    registry = DbRegistry()
      ..register(
        'prefs',
        KeyValueAdapter(
            type: 'hive', stores: () => [settings, MemoryStore('empty')]),
      )
      ..register('docs',
          DocumentAdapter(type: 'sembast', collections: () => [people]));
    router = InspectorRouter(
      registry: registry,
      config: () => const InspectorConfig(
        mode: InspectorMode.fullAccess,
        sensitiveColumns: {'*.age'},
      ),
    );
  });

  Future<Map<String, Object?>> call(String db, String method,
      [Map<String, Object?> p = const {}]) async {
    final r = jsonDecode(await router.handleRaw(jsonEncode({
      'method': method,
      'params': {'databaseId': db, ...p},
    }))) as Map<String, Object?>;
    return r;
  }

  Map<String, Object?> ok(Map<String, Object?> r) {
    expect(r['success'], isTrue, reason: '$r');
    return r['result']! as Map<String, Object?>;
  }

  group('registry', () {
    test('rejects duplicate ids for different adapters', () {
      final a = KeyValueAdapter(type: 'x', stores: () => const []);
      final r = DbRegistry()..register('My DB', a);
      expect(r.get('My_DB'), isNotNull);
      expect(
          () => r.register(
              'My DB', KeyValueAdapter(type: 'x', stores: () => const [])),
          throwsStateError);
      r.register('My DB', a); // same adapter: idempotent
      r.unregister('My DB');
      expect(r.databases, isEmpty);
    });
  });

  group('key/value engine', () {
    test('describes stores as boxes', () async {
      final list = ok(await call('prefs', Methods.databaseList));
      final prefs = (list['databases']! as List).first as Map;
      expect(prefs['dataModel'], 'keyValue');
      expect(prefs['capabilities'], isNot(contains('sql')));

      final schema = ok(await call('prefs', Methods.schemaList));
      final entities = schema['entities']! as List;
      expect(entities.map((e) => (e as Map)['name']), ['empty', 'settings']);
      expect((entities.last as Map)['kind'], 'box');
      expect((entities.last as Map)['rowCount'], 6);
    });

    test('lists entries with type info and custom objects via toJson',
        () async {
      final page =
          ok(await call('prefs', Methods.rowsQuery, {'table': 'settings'}));
      final rows = {
        for (final r in page['rows']! as List)
          ((r as Map)['values']! as List)[0]: r,
      };
      expect((rows['theme']!)['values'], ['theme', 'dark', 'String']);
      expect((rows['person']!)['values'], [
        'person',
        {
          r'$type': 'json',
          'value': {'name': 'Ravi', 'age': 31}
        },
        'Person',
      ]);
      expect((rows[7]!)['key'], {'key': 7});
    });

    test('filters, search and sorting', () async {
      final search = ok(await call(
          'prefs', Methods.rowsQuery, {'table': 'settings', 'search': 'asha'}));
      expect(search['total'], 1);
      final typed = ok(await call('prefs', Methods.rowsQuery, {
        'table': 'settings',
        'filters': [
          {'column': 'type', 'operator': 'equals', 'value': 'int'},
        ],
      }));
      expect(typed['total'], 1);
      final gt = ok(await call('prefs', Methods.rowsQuery, {
        'table': 'settings',
        'filters': [
          {'column': 'value', 'operator': 'greaterThan', 'value': '40'},
        ],
      }));
      expect(gt['total'], 1);
      final sorted = ok(await call('prefs', Methods.rowsQuery, {
        'table': 'settings',
        'sort': [
          {'column': 'key', 'direction': 'desc'},
        ],
      }));
      expect(((sorted['rows']! as List).first as Map)['key'], {'key': 'theme'});
    });

    test('insert, update, delete, clear', () async {
      ok(await call('prefs', Methods.rowInsert, {
        'table': 'settings',
        'values': {'key': 'locale', 'value': 'ta'},
      }));
      expect(settings.data['locale'], 'ta');
      expect(
        ((await call('prefs', Methods.rowInsert, {
          'table': 'settings',
          'values': {'key': 'locale', 'value': 'en'},
        }))['error']! as Map)['code'],
        'INVALID_REQUEST',
      );
      ok(await call('prefs', Methods.rowUpdate, {
        'table': 'settings',
        'key': {'key': 'profile'},
        'values': {
          'value': {
            r'$type': 'json',
            'value': {'name': 'Asha', 'tags': <String>[]}
          },
        },
      }));
      expect(settings.data['profile'], {'name': 'Asha', 'tags': <String>[]});
      ok(await call('prefs', Methods.rowDelete, {
        'table': 'settings',
        'key': {'key': 7},
      }));
      expect(settings.data.containsKey(7), isFalse);
      final cleared =
          ok(await call('prefs', Methods.tableClear, {'table': 'settings'}));
      expect(cleared['affectedRows'], 6);
    });

    test('SQL is not offered', () async {
      final r = await call('prefs', Methods.queryExecute, {'sql': 'SELECT 1'});
      expect((r['error']! as Map)['code'], 'UNSUPPORTED_OPERATION');
    });
  });

  group('document engine', () {
    test('infers fields of schemaless collections', () async {
      final schema =
          ok(await call('docs', Methods.schemaTable, {'table': 'people'}));
      final columns = ((schema['schema']! as Map)['columns']! as List)
          .map((c) => (c as Map)['name'])
          .toList();
      expect(columns, ['id', 'name', 'age', 'city']);
      expect((schema['schema']! as Map)['kind'], 'collection');
      expect(schema['sensitiveColumns'], ['age']);
    });

    test('pages, masks, filters and sorts documents', () async {
      final page = ok(await call('docs', Methods.rowsQuery,
          {'table': 'people', 'pageSize': 10, 'page': 2}));
      expect(page['total'], 30);
      final rows = page['rows']! as List;
      expect(rows, hasLength(10));
      final first = rows.first as Map;
      expect(first['key'], {'id': 21});
      expect(first['values'], [
        21,
        'P20',
        {r'$type': 'masked'},
        'Chennai'
      ]);

      final filtered = ok(await call('docs', Methods.rowsQuery, {
        'table': 'people',
        'filters': [
          {'column': 'city', 'operator': 'isNull'},
        ],
        'sort': [
          {'column': 'name', 'direction': 'desc'},
        ],
      }));
      expect(filtered['total'], 15);
      expect((((filtered['rows']! as List).first as Map)['values']! as List)[1],
          'P9');
    });

    test('mutations', () async {
      final inserted = ok(await call('docs', Methods.rowInsert, {
        'table': 'people',
        'values': {'name': 'New', 'age': 1},
      }));
      expect(inserted['insertedKey'], {'id': 31});
      ok(await call('docs', Methods.rowUpdate, {
        'table': 'people',
        'key': {'id': 31},
        'values': {'name': 'Renamed'},
      }));
      expect(people.docs[31]!['name'], 'Renamed');
      final idChange = await call('docs', Methods.rowUpdate, {
        'table': 'people',
        'key': {'id': 31},
        'values': {'id': 99},
      });
      expect((idChange['error']! as Map)['code'], 'UNSUPPORTED_OPERATION');
      ok(await call('docs', Methods.rowDelete, {
        'table': 'people',
        'key': {'id': 31},
      }));
      expect(people.docs.containsKey(31), isFalse);
    });

    test('string ids are typed as text and not auto-assigned', () async {
      final tags = _StringIdCollection();
      registry.register(
          'tags', DocumentAdapter(type: 'x', collections: () => [tags]));
      final schema =
          ok(await call('tags', Methods.schemaTable, {'table': 'tags'}));
      final id =
          (((schema['schema']! as Map)['columns']! as List).first as Map);
      expect(id['valueType'], 'text');
      expect(id['autoIncrement'], isFalse);
    });

    test('scans beyond the safety limit fail instead of stalling the app',
        () async {
      registry.register(
        'tiny',
        DocumentAdapter(
            type: 'x', collections: () => [people], maxScanDocuments: 5),
      );
      final r = await call(
          'tiny', Methods.rowsQuery, {'table': 'people', 'search': 'P1'});
      expect((r['error']! as Map)['code'], 'RESULT_TOO_LARGE');
    });
  });
}

final class _StringIdCollection extends MemoryCollection {
  _StringIdCollection() : super('tags');

  @override
  Future<List<Map<String, Object?>>> list(
          {required int offset, required int limit}) async =>
      [
        {'id': 'flutter', 'count': 3},
      ];
}

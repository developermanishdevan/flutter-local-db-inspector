import 'dart:convert';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_sqlite/flutter_db_inspector_sqlite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'seed.dart';

void main() {
  late Database db;
  late DbRegistry registry;
  late InspectorConfig config;
  late InspectorRouter router;

  setUp(() async {
    db = await openSeededDatabase();
    registry = DbRegistry()..register('main', SqliteAdapter(db));
    config = const InspectorConfig(
      mode: InspectorMode.fullAccess,
      sensitiveColumns: {'users.password'},
    );
    router = InspectorRouter(registry: registry, config: () => config);
  });

  tearDown(() => db.close());

  /// Sends a request exactly as a client would (JSON in, JSON out).
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final raw = await router.handleRaw(jsonEncode({
      'version': 1,
      'requestId': 'r1',
      'method': method,
      'params': {'databaseId': 'main', ...params},
    }));
    return jsonDecode(raw) as Map<String, Object?>;
  }

  Map<String, Object?> ok(Map<String, Object?> response) {
    expect(response['success'], isTrue, reason: '$response');
    expect(response['requestId'], 'r1');
    return response['result']! as Map<String, Object?>;
  }

  String errorCode(Map<String, Object?> response) {
    expect(response['success'], isFalse, reason: '$response');
    return (response['error']! as Map)['code'] as String;
  }

  group('discovery', () {
    test('database.list describes the database', () async {
      final result = ok(await call(Methods.databaseList));
      final dbs = result['databases']! as List;
      expect(dbs, hasLength(1));
      final main = dbs.single as Map;
      expect(main['id'], 'main');
      expect(main['type'], 'sqlite');
      expect(main['dataModel'], 'relational');
      expect(main['capabilities'], containsAll(['read', 'sql', 'update']));
      expect(main['readOnly'], isFalse);
    });

    test('database.info reports engine metadata', () async {
      final result = ok(await call(Methods.databaseInfo));
      final metadata = result['metadata']! as Map;
      expect(metadata['engine'], 'sqlite');
      expect(metadata['engineVersion'], matches(RegExp(r'^3\.')));
      expect(metadata['sizeBytes'], greaterThan(0));
    });

    test('schema.list lists tables, views, indexes and triggers', () async {
      final result = ok(await call(Methods.schemaList));
      final entities = {
        for (final e in result['entities']! as List) (e as Map)['name']: e,
      };
      expect(
          entities.keys,
          containsAll(
              ['users', 'orders', 'settings', 'samples', 'active_users']));
      expect(entities['users']!['rowCount'], 250);
      expect(entities['active_users']!['kind'], 'view');
      expect(entities['active_users']!['readOnly'], isTrue);
      final indexes = [
        for (final i in result['indexes']! as List) (i as Map)['name']
      ];
      expect(indexes, contains('idx_users_email'));
      final triggers = [
        for (final t in result['triggers']! as List) (t as Map)['name']
      ];
      expect(triggers, ['orders_status']);
    });

    test('schema.table describes columns, keys and constraints', () async {
      final schema = ok(await call(Methods.schemaTable, {'table': 'users'}));
      final table = schema['schema']! as Map;
      expect(table['rowKey'], 'rowid');
      final columns = {
        for (final c in table['columns']! as List) (c as Map)['name']: c,
      };
      expect(columns['id']!['primaryKeyPosition'], 1);
      expect(columns['id']!['autoIncrement'], isTrue);
      expect(columns['name']!['nullable'], isFalse);
      expect(columns['email']!['valueType'], 'text');
      expect(columns['is_active']!['valueType'], 'boolean');
      expect(schema['sensitiveColumns'], ['password']);

      final orders = ok(await call(Methods.schemaTable, {'table': 'orders'}));
      final fk =
          ((orders['schema']! as Map)['foreignKeys']! as List).single as Map;
      expect(fk['referencedTable'], 'users');
      expect(fk['onDelete'], 'CASCADE');

      final settings =
          ok(await call(Methods.schemaTable, {'table': 'settings'}));
      expect((settings['schema']! as Map)['rowKey'], 'primaryKey');
    });

    test('unknown table yields TABLE_NOT_FOUND', () async {
      expect(errorCode(await call(Methods.schemaTable, {'table': 'nope'})),
          'TABLE_NOT_FOUND');
      expect(errorCode(await call(Methods.rowsQuery, {'table': 'nope'})),
          'TABLE_NOT_FOUND');
    });

    test('unknown database and method', () async {
      final r = jsonDecode(await router.handleRaw(jsonEncode({
        'method': Methods.schemaList,
        'params': {'databaseId': 'missing'},
      }))) as Map<String, Object?>;
      expect((r['error']! as Map)['code'], 'DATABASE_NOT_FOUND');
      expect(errorCode(await call('rows.teleport')), 'UNSUPPORTED_OPERATION');
    });

    test('malformed JSON and future protocol versions are rejected', () async {
      final bad = jsonDecode(await router.handleRaw('{nope')) as Map;
      expect((bad['error']! as Map)['code'], 'INVALID_REQUEST');
      final future = jsonDecode(await router.handleRaw(jsonEncode({
        'version': 99,
        'method': Methods.databaseList,
      }))) as Map;
      expect((future['error']! as Map)['code'], 'UNSUPPORTED_PROTOCOL_VERSION');
    });
  });

  group('rows.query', () {
    test('paginates with defaults and clamps the page size', () async {
      final page = ok(await call(Methods.rowsQuery, {'table': 'users'}));
      expect(page['total'], 250);
      expect(page['pageSize'], 50);
      expect(page['rows'] as List, hasLength(50));

      final big = ok(
          await call(Methods.rowsQuery, {'table': 'users', 'pageSize': 5000}));
      expect(big['pageSize'], 100);
      expect(big['rows'] as List, hasLength(100));

      final last =
          ok(await call(Methods.rowsQuery, {'table': 'users', 'page': 4}));
      final row = (last['rows']! as List).first as Map;
      expect(row['key'], {'rowid': 201});
    });

    test('masks sensitive columns', () async {
      final page =
          ok(await call(Methods.rowsQuery, {'table': 'users', 'pageSize': 1}));
      final names = [
        for (final c in page['columns']! as List) (c as Map)['name']
      ];
      final values = ((page['rows']! as List).first as Map)['values']! as List;
      expect(values[names.indexOf('password')], {r'$type': 'masked'});
      expect(values[names.indexOf('name')], 'User 1');
    });

    test('masked columns cannot be filtered, sorted, searched or read',
        () async {
      expect(
        errorCode(await call(Methods.rowsQuery, {
          'table': 'users',
          'filters': [
            {'column': 'password', 'operator': 'equals', 'value': 'secret-1'},
          ],
        })),
        'PERMISSION_DENIED',
      );
      final searched = ok(await call(
          Methods.rowsQuery, {'table': 'users', 'search': 'secret-1'}));
      expect(searched['total'], 0);
      expect(
        errorCode(await call(Methods.valueRead, {
          'table': 'users',
          'key': {'rowid': 1},
          'column': 'password',
        })),
        'PERMISSION_DENIED',
      );
    });

    test('filters, search and sort', () async {
      Future<int> total(Map<String, Object?> params) async =>
          ok(await call(Methods.rowsQuery, {'table': 'users', ...params}))[
              'total']! as int;

      expect(await total({'search': 'zoë'}), 1);
      expect(await total({'search': '100%'}), 0,
          reason: 'LIKE wildcards are escaped');
      expect(
        await total({
          'filters': [
            {'column': 'email', 'operator': 'isNull'},
          ],
        }),
        25,
      );
      expect(
        await total({
          'filters': [
            {'column': 'id', 'operator': 'greaterThan', 'value': '240'},
            {'column': 'is_active', 'operator': 'equals', 'value': true},
          ],
        }),
        5,
      );
      expect(
        await total({
          'filters': [
            {'column': 'name', 'operator': 'startsWith', 'value': 'User 1'},
          ],
        }),
        111,
      );

      final sorted = ok(await call(Methods.rowsQuery, {
        'table': 'users',
        'pageSize': 3,
        'sort': [
          {'column': 'created_at', 'direction': 'desc'},
        ],
      }));
      final first = ((sorted['rows']! as List).first as Map)['values']! as List;
      expect(first.first, 250);

      expect(
        errorCode(await call(Methods.rowsQuery, {
          'table': 'users',
          'sort': [
            {'column': 'nope'},
          ],
        })),
        'COLUMN_NOT_FOUND',
      );
    });

    test('rows.count honours filters', () async {
      final r = ok(await call(Methods.rowsCount, {
        'table': 'orders',
        'filters': [
          {'column': 'status', 'operator': 'equals', 'value': 'shipped'},
        ],
      }));
      expect(r['count'], 83);
    });

    test('encodes edge-case values safely', () async {
      final page = ok(await call(Methods.rowsQuery, {'table': 'samples'}));
      final names = [
        for (final c in page['columns']! as List) (c as Map)['name']
      ];
      final rows = page['rows']! as List;
      final values = (rows.first as Map)['values']! as List;
      Object? cell(String name) => values[names.indexOf(name)];

      expect(cell('label'), '');
      expect(cell('payload'), '{"name":"John","active":true}');
      expect(cell('big'), {r'$type': 'bigint', 'value': '9007199254740993'});
      expect(cell('ratio'), 3.14159);
      final blob = cell('data')! as Map;
      expect(blob[r'$type'], 'blob');
      expect(blob['size'], 65536);
      expect(blob['truncated'], isTrue);
      final notes = cell('notes')! as Map;
      expect(notes[r'$type'], 'text');
      expect(notes['size'], 50000);
      expect(
          (notes['preview']! as String).length, lessThanOrEqualTo(10 * 1024));

      final second = (rows[1] as Map)['values']! as List;
      expect(second[names.indexOf('label')], isNull);
    });

    test('views are readable but rows are not addressable', () async {
      final page = ok(await call(
          Methods.rowsQuery, {'table': 'active_users', 'pageSize': 2}));
      expect(page['total'], 125);
      expect(((page['rows']! as List).first as Map)['key'], isNull);
    });

    test('value.read streams large values in chunks', () async {
      final first = ok(await call(Methods.valueRead, {
        'table': 'samples',
        'key': {'rowid': 1},
        'column': 'data',
        'length': 1000,
      }));
      expect(first['totalBytes'], 65536);
      expect(first['isText'], isFalse);
      expect(base64Decode(first['base64']! as String),
          List.generate(1000, (i) => i % 256));
      final tail = ok(await call(Methods.valueRead, {
        'table': 'samples',
        'key': {'rowid': 1},
        'column': 'data',
        'offset': 65000,
      }));
      expect(tail['length'], 536);
      expect(tail['done'], isTrue);
    });

    test('oversized responses fall back to compact previews', () async {
      config = config.copyWith(
        limits: const InspectorLimits(maxResponseBytes: 8 * 1024),
      );
      final page = ok(await call(Methods.rowsQuery, {'table': 'samples'}));
      final notes = (((page['rows']! as List).first as Map)['values']! as List)
          .last as Map;
      expect((notes['preview']! as String).length, lessThanOrEqualTo(256));

      config =
          config.copyWith(limits: const InspectorLimits(maxResponseBytes: 512));
      expect(
        errorCode(
            await call(Methods.rowsQuery, {'table': 'users', 'pageSize': 100})),
        'RESULT_TOO_LARGE',
      );
    });
  });

  group('mutations', () {
    test('insert, update and delete by rowid', () async {
      final inserted = ok(await call(Methods.rowInsert, {
        'table': 'users',
        'values': {'name': 'New', 'is_active': true, 'created_at': 1},
      }));
      expect(inserted['insertedKey'], {'rowid': 251});

      ok(await call(Methods.rowUpdate, {
        'table': 'users',
        'key': {'rowid': 251},
        'values': {'name': 'Renamed', 'email': null},
      }));
      final row = await db.query('users', where: 'id = 251');
      expect(row.single['name'], 'Renamed');
      expect(row.single['is_active'], 1);

      ok(await call(Methods.rowDelete, {
        'table': 'users',
        'key': {'rowid': 251},
      }));
      expect(await db.query('users', where: 'id = 251'), isEmpty);
      expect(
        errorCode(await call(Methods.rowDelete, {
          'table': 'users',
          'key': {'rowid': 251},
        })),
        'ROW_NOT_FOUND',
      );
    });

    test('composite primary keys (WITHOUT ROWID)', () async {
      final page = ok(await call(Methods.rowsQuery, {'table': 'settings'}));
      final key = ((page['rows']! as List).first as Map)['key'];
      expect(key, {'scope': 'app', 'key': 'locale'});
      ok(await call(Methods.rowUpdate, {
        'table': 'settings',
        'key': key,
        'values': {'value': 'ta'},
      }));
      final rows = await db.query('settings', where: "key = 'locale'");
      expect(rows.single['value'], 'ta');
    });

    test('views and constraint violations are reported cleanly', () async {
      expect(
        errorCode(await call(Methods.rowInsert, {
          'table': 'active_users',
          'values': {'name': 'x'},
        })),
        'UNSUPPORTED_OPERATION',
      );
      final r = await call(Methods.rowInsert, {
        'table': 'users',
        'values': {'name': null, 'created_at': 1},
      });
      expect(errorCode(r), 'QUERY_FAILED');
      expect(
          ((r['error']! as Map)['message']! as String), contains('NOT NULL'));
    });

    test('table.clear', () async {
      final r = ok(await call(Methods.tableClear, {'table': 'orders'}));
      expect(r['affectedRows'], 250);
    });

    test('read-only mode and read-only databases block writes', () async {
      config = config.copyWith(mode: InspectorMode.readOnly);
      final r = await call(Methods.rowDelete, {
        'table': 'users',
        'key': {'rowid': 1},
      });
      expect(errorCode(r), 'WRITE_NOT_ALLOWED');
      final list = ok(await call(Methods.databaseList));
      expect(((list['databases']! as List).single as Map)['readOnly'], isTrue);

      config = config.copyWith(mode: InspectorMode.fullAccess);
      registry.register('ro', SqliteAdapter(db), readOnly: true);
      final ro = jsonDecode(await router.handleRaw(jsonEncode({
        'method': Methods.tableClear,
        'params': {'databaseId': 'ro', 'table': 'users'},
      }))) as Map;
      expect((ro['error']! as Map)['code'], 'WRITE_NOT_ALLOWED');
    });
  });

  group('query.execute', () {
    test('runs bounded read queries', () async {
      final r = ok(await call(Methods.queryExecute, {
        'sql':
            'SELECT id, name FROM users WHERE is_active = ? ORDER BY id DESC',
        'arguments': [1],
        'maxRows': 10,
      }));
      expect(r['kind'], 'read');
      expect(r['rowCount'], 10);
      expect(r['truncated'], isTrue);
      expect([for (final c in r['columns']! as List) (c as Map)['name']],
          ['id', 'name']);
      expect((r['rows']! as List).first, [250, 'User 250']);
      expect(r['elapsedMs'], isA<num>());
    });

    test('masks sensitive columns by name', () async {
      final r = ok(await call(Methods.queryExecute, {
        'sql': 'SELECT name, password FROM users LIMIT 1',
      }));
      expect((r['rows']! as List).first, [
        'User 1',
        {r'$type': 'masked'}
      ]);
    });

    test('writes require explicit confirmation', () async {
      final blocked = await call(Methods.queryExecute, {
        'sql': 'DELETE FROM orders WHERE id = 1',
      });
      expect(errorCode(blocked), 'WRITE_NOT_ALLOWED');
      expect(
          ((blocked['error']! as Map)['details']!
              as Map)['requiresConfirmation'],
          isTrue);
      expect(await db.query('orders', where: 'id = 1'), isNotEmpty);

      final done = ok(await call(Methods.queryExecute, {
        'sql': 'DELETE FROM orders WHERE id <= 3',
        'allowWrite': true,
      }));
      expect(done['kind'], 'write');
      expect(done['affectedRows'], 3);

      final insert = ok(await call(Methods.queryExecute, {
        'sql': "INSERT INTO orders (user_id, status) VALUES (1, 'new')",
        'allowWrite': true,
      }));
      expect(insert['lastInsertId'], 251);
      expect(insert['affectedRows'], 1);
    });

    test('read-only mode never allows writes, even when confirmed', () async {
      config = config.copyWith(mode: InspectorMode.readOnly);
      final r = await call(Methods.queryExecute, {
        'sql': 'DROP TABLE orders',
        'allowWrite': true,
      });
      expect(errorCode(r), 'WRITE_NOT_ALLOWED');
      expect(((r['error']! as Map)['details']! as Map)['requiresConfirmation'],
          isFalse);
    });

    test('rejects multiple statements and reports SQL errors', () async {
      expect(
        errorCode(
            await call(Methods.queryExecute, {'sql': 'SELECT 1; SELECT 2'})),
        'INVALID_REQUEST',
      );
      final r =
          await call(Methods.queryExecute, {'sql': 'SELECT * FROM missing'});
      expect(errorCode(r), 'QUERY_FAILED');
      expect(((r['error']! as Map)['message']! as String),
          contains('no such table'));
    });
  });

  test('database.stats', () async {
    final stats = ok(await call(Methods.databaseStats));
    expect(stats['totalRows'], 250 + 250 + 2 + 2);
    expect(stats['indexCount'], greaterThanOrEqualTo(1));
    expect(stats['sizeBytes'], greaterThan(0));
  });

  test('inspector.status advertises methods and limits', () async {
    final status = ok(await call(Methods.inspectorStatus));
    expect(status['protocolVersion'], 1);
    expect(status['mode'], 'fullAccess');
    expect(status['methods'],
        containsAll([Methods.rowsQuery, Methods.queryExecute]));
    expect((status['limits']! as Map)['maxPageSize'], 100);
  });

  test('disabled inspector answers nothing', () async {
    config = const InspectorConfig();
    expect(errorCode(await call(Methods.databaseList)), 'INSPECTOR_DISABLED');
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_drift/flutter_db_inspector_drift.dart';
import 'package:test/test.dart';

import 'support/app_database.dart';

/// Seeds 100 users (every 10th without email, odd ids inactive, user 7 named
/// "Zoë") and 30 todos.
Future<void> seed(AppDatabase db) async {
  await db.batch((b) {
    b.insertAll(db.users, [
      for (var i = 1; i <= 100; i++)
        UsersCompanion.insert(
          name: i == 7 ? 'Zoë' : 'User $i',
          email: Value(i % 10 == 0 ? null : 'user$i@example.com'),
          isActive: Value(i.isEven),
        ),
    ]);
    b.insertAll(db.todos, [
      for (var i = 1; i <= 30; i++)
        TodosCompanion.insert(title: 'Todo $i', userId: Value(i % 5 + 1)),
    ]);
  });
}

void main() {
  late AppDatabase db;
  late DbRegistry registry;
  late InspectorConfig config;
  late InspectorRouter router;

  setUp(() async {
    db = AppDatabase();
    await seed(db);
    registry = DbRegistry()..register('main', DriftAdapter(db));
    config = const InspectorConfig(mode: InspectorMode.fullAccess);
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
    return response['result']! as Map<String, Object?>;
  }

  String errorCode(Map<String, Object?> response) {
    expect(response['success'], isFalse, reason: '$response');
    return (response['error']! as Map)['code'] as String;
  }

  Future<int> total(String table, Map<String, Object?> params) async =>
      ok(await call(Methods.rowsQuery, {'table': table, ...params}))['total']!
          as int;

  group('discovery', () {
    test('database.list reports a relational drift database', () async {
      final dbs = ok(await call(Methods.databaseList))['databases']! as List;
      final main = dbs.single as Map;
      expect(main['type'], 'drift');
      expect(main['dataModel'], 'relational');
      expect(main['capabilities'], containsAll(['read', 'sql', 'update']));
    });

    test('database.info adds drift metadata', () async {
      final metadata = ok(await call(Methods.databaseInfo))['metadata']! as Map;
      expect(metadata['engine'], 'sqlite');
      expect(metadata['engineVersion'], matches(RegExp(r'^3\.')));
      final extra = metadata['extra']! as Map;
      expect(extra['schemaVersion'], 3);
      expect((extra['driftTables']! as Map).keys,
          unorderedEquals(['users', 'todos']));
    });

    test('schema.list and schema.table describe the generated schema',
        () async {
      final result = ok(await call(Methods.schemaList));
      final entities = {
        for (final e in result['entities']! as List) (e as Map)['name']: e,
      };
      expect(entities.keys, unorderedEquals(['users', 'todos']));
      expect(entities['users']!['rowCount'], 100);
      expect(entities['todos']!['rowCount'], 30);

      final users = ok(await call(Methods.schemaTable, {'table': 'users'}));
      final table = users['schema']! as Map;
      expect(table['rowKey'], 'rowid');
      final columns = {
        for (final c in table['columns']! as List) (c as Map)['name']: c,
      };
      expect(columns.keys,
          containsAll(['id', 'name', 'email', 'is_active', 'avatar']));
      expect(columns['id']!['autoIncrement'], isTrue);
      expect(columns['name']!['nullable'], isFalse);
      expect(columns['avatar']!['valueType'], 'blob');

      final todos = ok(await call(Methods.schemaTable, {'table': 'todos'}));
      final fk =
          ((todos['schema']! as Map)['foreignKeys']! as List).single as Map;
      expect(fk['referencedTable'], 'users');

      expect(errorCode(await call(Methods.schemaTable, {'table': 'nope'})),
          'TABLE_NOT_FOUND');
    });
  });

  group('rows.query', () {
    test('pages through rows', () async {
      final first = ok(await call(
          Methods.rowsQuery, {'table': 'users', 'pageSize': 30, 'page': 0}));
      expect(first['total'], 100);
      expect(first['rows'] as List, hasLength(30));
      final last = ok(await call(
          Methods.rowsQuery, {'table': 'users', 'pageSize': 30, 'page': 3}));
      final rows = last['rows']! as List;
      expect(rows, hasLength(10));
      expect((rows.first as Map)['key'], {'rowid': 91});
    });

    test('filters, search and sort', () async {
      expect(await total('users', {'search': 'zoë'}), 1);
      expect(
        await total('users', {
          'filters': [
            {'column': 'email', 'operator': 'isNull'},
          ],
        }),
        10,
      );
      expect(
        await total('users', {
          'filters': [
            {'column': 'id', 'operator': 'greaterThan', 'value': 90},
            {'column': 'is_active', 'operator': 'equals', 'value': true},
          ],
        }),
        5,
      );

      final sorted = ok(await call(Methods.rowsQuery, {
        'table': 'users',
        'pageSize': 2,
        'sort': [
          {'column': 'id', 'direction': 'desc'},
        ],
      }));
      final page = ok(await call(Methods.rowsQuery, {'table': 'users'}));
      final names = [
        for (final c in page['columns']! as List) (c as Map)['name']
      ];
      final top = ((sorted['rows']! as List).first as Map)['values']! as List;
      expect(top[names.indexOf('id')], 100);
      expect(top[names.indexOf('name')], 'User 100');
    });
  });

  group('mutations', () {
    test('insert, update and delete', () async {
      final inserted = ok(await call(Methods.rowInsert, {
        'table': 'users',
        'values': {'name': 'New', 'is_active': false},
      }));
      expect(inserted['insertedKey'], {'rowid': 101});

      ok(await call(Methods.rowUpdate, {
        'table': 'users',
        'key': {'rowid': 101},
        'values': {'name': 'Renamed', 'email': null},
      }));
      final user = await (db.select(db.users)..where((u) => u.id.equals(101)))
          .getSingle();
      expect(user.name, 'Renamed');
      expect(user.email, isNull);
      expect(user.isActive, isFalse);

      ok(await call(Methods.rowDelete, {
        'table': 'users',
        'key': {'rowid': 101},
      }));
      expect(
        await (db.select(db.users)..where((u) => u.id.equals(101))).get(),
        isEmpty,
      );
      expect(
        errorCode(await call(Methods.rowDelete, {
          'table': 'users',
          'key': {'rowid': 101},
        })),
        'ROW_NOT_FOUND',
      );
    });

    test('blob values written through drift are readable', () async {
      await (db.update(db.users)..where((u) => u.id.equals(1))).write(
        UsersCompanion(avatar: Value(Uint8List.fromList([1, 2, 3]))),
      );
      final chunk = ok(await call(Methods.valueRead, {
        'table': 'users',
        'key': {'rowid': 1},
        'column': 'avatar',
      }));
      expect(base64Decode(chunk['base64']! as String), [1, 2, 3]);
      expect(chunk['isText'], isFalse);
    });

    test('table.clear', () async {
      final r = ok(await call(Methods.tableClear, {'table': 'todos'}));
      expect(r['affectedRows'], 30);
      expect(await db.select(db.todos).get(), isEmpty);
    });
  });

  group('query.execute', () {
    test('reads with arguments', () async {
      final r = ok(await call(Methods.queryExecute, {
        'sql': 'SELECT id, name FROM users WHERE is_active = ? ORDER BY id '
            'DESC',
        'arguments': [true],
        'maxRows': 5,
      }));
      expect(r['kind'], 'read');
      expect(r['truncated'], isTrue);
      expect((r['rows']! as List).first, [100, 'User 100']);
    });

    test('writes require explicit confirmation', () async {
      final blocked = await call(Methods.queryExecute, {
        'sql': 'DELETE FROM todos WHERE id = 1',
      });
      expect(errorCode(blocked), 'WRITE_NOT_ALLOWED');
      expect(
        ((blocked['error']! as Map)['details']! as Map)['requiresConfirmation'],
        isTrue,
      );
      expect(await db.select(db.todos).get(), hasLength(30));

      final deleted = ok(await call(Methods.queryExecute, {
        'sql': 'DELETE FROM todos WHERE id <= 3',
        'allowWrite': true,
      }));
      expect(deleted['kind'], 'write');
      expect(deleted['affectedRows'], 3);

      final inserted = ok(await call(Methods.queryExecute, {
        'sql': "INSERT INTO todos (title) VALUES ('fresh')",
        'allowWrite': true,
      }));
      expect(inserted['lastInsertId'], 31);
      expect(inserted['affectedRows'], 1);

      final r = await call(Methods.queryExecute, {'sql': 'SELECT * FROM nope'});
      expect(errorCode(r), 'QUERY_FAILED');
    });
  });

  group('stream notification', () {
    test('row.update refreshes generated select().watch() streams', () async {
      final names = StreamQueue(
        (db.select(db.users)..where((u) => u.id.equals(1)))
            .watchSingle()
            .map((u) => u.name),
      );
      expect(await names.next, 'User 1');

      ok(await call(Methods.rowUpdate, {
        'table': 'users',
        'key': {'rowid': 1},
        'values': {'name': 'Edited in inspector'},
      }));
      expect(await names.next.timeout(const Duration(seconds: 2)),
          'Edited in inspector');
      await names.cancel();
    });

    test('row edits only notify the edited table', () async {
      final userCount = StreamQueue(db
          .customSelect('SELECT COUNT(*) AS c FROM users',
              readsFrom: {db.users})
          .watchSingle()
          .map((r) => r.read<int>('c')));
      final todoTitles = StreamQueue(db.customSelect(
          'SELECT title FROM todos ORDER BY id',
          readsFrom: {db.todos}).watch());
      expect(await userCount.next, 100);
      expect(await todoTitles.next, hasLength(30));

      ok(await call(Methods.rowInsert, {
        'table': 'users',
        'values': {'name': 'Streamed'},
      }));
      expect(await userCount.next.timeout(const Duration(seconds: 2)), 101);

      ok(await call(Methods.rowDelete, {
        'table': 'users',
        'key': {'rowid': 101},
      }));
      expect(await userCount.next.timeout(const Duration(seconds: 2)), 100);

      // The todos stream must not have been re-run for users edits.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
          await todoTitles.hasNext.timeout(Duration.zero, onTimeout: () {
            return false;
          }),
          isFalse);

      await userCount.cancel();
      await todoTitles.cancel(immediate: true);
    });

    test('SQL console writes notify every table', () async {
      final todoCount = StreamQueue(db
          .customSelect('SELECT COUNT(*) AS c FROM todos',
              readsFrom: {db.todos})
          .watchSingle()
          .map((r) => r.read<int>('c')));
      expect(await todoCount.next, 30);

      ok(await call(Methods.queryExecute, {
        'sql': 'DELETE FROM todos WHERE id > 10',
        'allowWrite': true,
      }));
      expect(await todoCount.next.timeout(const Duration(seconds: 2)), 10);

      await todoCount.cancel();

      // Other statements (DDL, PRAGMA, ...) run through `execute` and notify
      // every table as well.
      final updates = StreamQueue(db.tableUpdates());
      ok(await call(Methods.queryExecute, {
        'sql': 'CREATE INDEX idx_todos_title ON todos (title)',
        'allowWrite': true,
      }));
      final notified = await updates.next.timeout(const Duration(seconds: 2));
      expect(
        notified.map((u) => u.table),
        containsAll(['users', 'todos']),
      );
      await updates.cancel(immediate: true);
    });
  });
}

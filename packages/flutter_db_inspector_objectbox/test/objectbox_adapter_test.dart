@Tags(['native'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_objectbox/flutter_db_inspector_objectbox.dart';
import 'package:objectbox/objectbox.dart';
import 'package:test/test.dart';

import 'entities.dart';
import 'native_library.dart';
import 'objectbox.g.dart' show openStore;

void main() {
  late Directory dir;
  late Store store;
  late Box<Task> tasks;
  late InspectorRouter router;

  setUpAll(loadObjectBoxLibrary);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('db_inspector_objectbox');
    store = openStore(directory: dir.path);
    tasks = store.box<Task>();
    tasks.putMany([
      for (var i = 0; i < 30; i++)
        Task(
          title: 'T$i',
          priority: i % 5 == 4 ? null : i,
          done: i.isEven,
          due: DateTime.utc(2024, 1, 1 + i),
          tags: ['g${i % 3}'],
        ),
    ]);
    final registry = DbRegistry()
      ..register(
        'obx',
        ObjectBoxAdapter(store, [
          ObjectBoxCollection<Task>(
            tasks,
            name: 'Task',
            toJson: (t) => t.toJson(),
            fromJson: Task.fromJson,
            getId: (t) => t.id,
          ),
        ]),
      );
    router = InspectorRouter(
      registry: registry,
      config: () => const InspectorConfig(mode: InspectorMode.fullAccess),
    );
  });

  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> call(String method,
      [Map<String, Object?> p = const {}]) async {
    return jsonDecode(await router.handleRaw(jsonEncode({
      'method': method,
      'params': {'databaseId': 'obx', ...p},
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

  test('lists boxes and infers columns', () async {
    final list = ok(await call(Methods.databaseList));
    final db = (list['databases']! as List).single as Map;
    expect(db['type'], 'objectbox');
    expect(db['dataModel'], 'document');
    expect(jsonEncode(ok(await call(Methods.databaseInfo))),
        contains(Store.databaseVersion()));

    final schema = ok(await call(Methods.schemaList));
    final entity = (schema['entities']! as List).single as Map;
    expect(entity['name'], 'Task');
    expect(entity['kind'], 'collection');
    expect(entity['rowCount'], 30);

    final table = ok(await call(Methods.schemaTable, {'table': 'Task'}));
    expect(
      [
        for (final c in (table['schema']! as Map)['columns']! as List)
          (c as Map)['name'],
      ],
      ['id', 'title', 'priority', 'done', 'due', 'tags'],
    );
  });

  test('pages, filters and sorts', () async {
    final page = await rows({'table': 'Task', 'pageSize': 10, 'page': 2});
    expect(page['total'], 30);
    final first = (page['rows']! as List).first as Map;
    expect(first['key'], {'id': 21});
    expect(first['values'], [
      21,
      'T20',
      20,
      true,
      {r'$type': 'dateTime', 'value': '2024-01-21T00:00:00.000Z'},
      {
        r'$type': 'json',
        'value': ['g2'],
      },
    ]);

    final filtered = await rows({
      'table': 'Task',
      'pageSize': 2,
      'filters': [
        {'column': 'priority', 'operator': 'isNull'},
      ],
      'sort': [
        {'column': 'title', 'direction': 'desc'},
      ],
    });
    expect(filtered['total'], 6);
    expect([
      for (final r in filtered['rows']! as List) (r as Map)['key']
    ], [
      {'id': 10},
      {'id': 5},
    ]);
    expect((await rows({'table': 'Task', 'search': 'g1'}))['total'], 10);
  });

  test('insert, update, delete and clear', () async {
    final inserted = ok(await call(Methods.rowInsert, {
      'table': 'Task',
      'values': {
        'title': 'New',
        'priority': 1,
        'due': {r'$type': 'dateTime', 'value': '2025-02-03T00:00:00.000Z'},
      },
    }));
    expect(inserted['insertedKey'], {'id': 31});
    final task = tasks.get(31)!;
    expect(task.title, 'New');
    expect(task.due!.toUtc(), DateTime.utc(2025, 2, 3));

    expect(
      errorCode(await call(Methods.rowInsert, {
        'table': 'Task',
        'values': {'id': 1, 'title': 'dup'},
      })),
      'INVALID_REQUEST',
    );

    ok(await call(Methods.rowUpdate, {
      'table': 'Task',
      'key': {'id': 1},
      'values': {'title': 'Renamed', 'priority': null},
    }));
    final updated = tasks.get(1)!;
    expect(updated.title, 'Renamed');
    expect(updated.priority, isNull);
    expect(updated.tags, ['g0'], reason: 'untouched fields are kept');
    expect(
      errorCode(await call(Methods.rowUpdate, {
        'table': 'Task',
        'key': {'id': 1},
        'values': {'priority': 'high'},
      })),
      'INVALID_REQUEST',
    );
    expect(
      errorCode(await call(Methods.rowUpdate, {
        'table': 'Task',
        'key': {'id': 999},
        'values': {'title': 'x'},
      })),
      'ROW_NOT_FOUND',
    );

    ok(await call(Methods.rowDelete, {
      'table': 'Task',
      'key': {'id': 2},
    }));
    expect(tasks.get(2), isNull);

    final cleared = ok(await call(Methods.tableClear, {'table': 'Task'}));
    expect(cleared['affectedRows'], 30);
    expect(tasks.isEmpty(), isTrue);
  });
}

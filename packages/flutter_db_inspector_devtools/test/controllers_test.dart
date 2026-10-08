import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:flutter_db_inspector_devtools/services/connection_manager.dart';
import 'package:flutter_db_inspector_devtools/services/history_storage.dart';
import 'package:flutter_db_inspector_devtools/services/inspector_controller.dart';
import 'package:flutter_db_inspector_devtools/services/query_history.dart';
import 'package:flutter_db_inspector_devtools/services/sql_controller.dart';
import 'package:flutter_db_inspector_devtools/services/table_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import 'support/fake_backend.dart';

DatabaseDescriptor _db({bool readOnly = false, Set<DbCapability>? caps}) =>
    DatabaseDescriptor(
      id: 'app',
      name: 'app_database',
      type: 'sqlite',
      readOnly: readOnly,
      capabilities: caps ?? DbCapability.values.toSet(),
    );

const _users =
    EntitySummary(name: 'users', kind: EntityKind.table, rowCount: 60);

Future<TableController> _table(FakeBackend backend,
    {DatabaseDescriptor? db, EntitySummary entity = _users}) async {
  final c = TableController(
      client: InspectorClient(backend), database: db ?? _db(), entity: entity);
  await c.reload(withSchema: true);
  return c;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('TableController', () {
    test('loads schema and the first page', () async {
      final c = await _table(FakeBackend());
      expect(c.page!.rows, hasLength(50));
      expect(c.page!.total, 60);
      expect(c.pageCount, 2);
      expect(c.hasNextPage, isTrue);
      expect(c.statusText, startsWith('1–50 of 60 rows'));
      expect(
          c.gridColumns.firstWhere((g) => g.name == 'password').masked, isTrue);
      expect(c.gridColumns.first.primaryKey, isTrue);
      expect(c.filterableColumns.map((col) => col.name),
          isNot(contains('password')));
    });

    test('search, sort and paging go to the server', () async {
      final backend = FakeBackend();
      final c = await _table(backend);
      c.setSearch('  User 1 ');
      await _settle();
      expect(
          (jsonDecode(backend.calls(Methods.rowsQuery).last) as Map)['search'],
          'User 1');
      expect(c.page!.total, 11); // User 1, User 10–19
      c.toggleSort('name');
      await _settle();
      expect(c.sort.single.direction, SortDirection.asc);
      c.toggleSort('name');
      await _settle();
      expect(c.sort.single.direction, SortDirection.desc);
      c.toggleSort('name');
      await _settle();
      expect(c.sort, isEmpty);
      c
        ..setSearch('')
        ..setPageSize(25);
      await _settle();
      c.goToPage(2);
      await _settle();
      expect(c.pageIndex, 2);
      expect(c.page!.rows, hasLength(10));
      expect(c.hasNextPage, isFalse);
      expect(c.statusText, startsWith('51–60 of 60 rows'));
    });

    test('edit rules: masked, blob, partial, views, read-only', () async {
      final c = await _table(FakeBackend());
      const name = 1, password = 3, big = 4, data = 5, notes = 6, meta = 7;
      expect(c.canEditCell(0, name), isTrue);
      expect(c.canEditCell(0, big), isTrue); // bigint stays exact
      expect(c.canEditCell(2, meta), isTrue); // json
      expect(c.canEditCell(0, password), isFalse); // masked
      expect(c.canEditCell(0, data), isFalse); // blob
      expect(c.canEditCell(1, notes), isFalse); // truncated text
      expect(c.canEditValue(1, notes), isTrue); // after loading the full value

      final view = await _table(
        FakeBackend(),
        entity: const EntitySummary(
            name: 'active_users', kind: EntityKind.view, readOnly: true),
      );
      expect(view.writable, isFalse);
      expect(view.canEditCell(0, name), isFalse);

      final ro =
          await _table(FakeBackend(readOnly: true), db: _db(readOnly: true));
      expect(ro.canUpdate, isFalse);
      expect(ro.canInsert, isFalse);

      final noUpdate =
          await _table(FakeBackend(), db: _db(caps: {DbCapability.read}));
      expect(noUpdate.canEditCell(0, name), isFalse);
    });

    test('commitEdit parses by column type and reloads', () async {
      final backend = FakeBackend();
      final c = await _table(backend);
      expect(await c.commitEdit(0, 4, '9007199254740995'), isTrue);
      final update = jsonDecode(backend.calls(Methods.rowUpdate).single) as Map;
      expect(update['key'], {'rowid': 1});
      expect(update['values'], {
        'big': {r'$type': 'bigint', 'value': '9007199254740995'},
      });
      expect(c.message, 'Saved big');
      expect(
          c.page!.rows.first.values[4], const WireBigInt('9007199254740995'));
    });

    test('errors are kept for display', () async {
      final backend = FakeBackend(readOnly: true);
      final c = await _table(backend);
      expect(await c.setNull(0, 2), isFalse);
      expect(c.error, contains('WRITE_NOT_ALLOWED'));
    });

    test('delete, insert, clear', () async {
      final backend = FakeBackend();
      final c = await _table(backend);
      expect(await c.deleteRow(0), isTrue);
      expect(c.page!.total, 59);
      await c.insertRow({'name': const WireString('New')});
      expect(c.page!.total, 60);
      expect(await c.clearTable(), 60);
      expect(c.page!.total, 0);
      expect(c.message, 'Deleted 60 rows');
    });

    test('duplicate leaves out keys, masked, partial and binary values',
        () async {
      final c = await _table(FakeBackend());
      final first = c.duplicateValues(0);
      expect(first.keys, containsAll(['name', 'email', 'big']));
      expect(first.keys, isNot(contains('id'))); // auto-increment key
      expect(first.keys, isNot(contains('password')));
      expect(first.keys, isNot(contains('data')));
      expect(c.duplicateValues(1).keys, isNot(contains('notes')));
    });

    test('copy row as JSON keeps big integers exact', () async {
      final c = await _table(FakeBackend());
      final json = c.rowJson(0);
      expect(json, contains('"big": 9007199254740993'));
      expect(json, contains('"password": null'));
      expect(c.copyCellText(0, 4), '9007199254740993');
      expect(c.keyLabel(0), 'rowid = 1');
    });

    test('buildFilter parses by type except for text operators', () async {
      final c = await _table(FakeBackend());
      expect(c.buildFilter('id', FilterOperator.greaterThan, '5').value, 5);
      expect(c.buildFilter('id', FilterOperator.contains, '5').value, '5');
      expect(c.buildFilter('email', FilterOperator.isNull, 'x').toJson(),
          {'column': 'email', 'operator': 'isNull'});
    });

    test('loadFullValue streams value.read', () async {
      final c = await _table(FakeBackend());
      final full = await c.loadFullValue(1, 6);
      expect(full.text, 'Lorem ipsum full value');
    });
  });

  group('SqlController', () {
    late FakeBackend backend;
    late SqlController sql;

    setUp(() {
      backend = FakeBackend();
      sql = SqlController(
        client: InspectorClient(backend),
        database: _db(),
        history: QueryHistory(storage: MemoryHistoryStorage()),
      );
    });

    test('read results, status and history', () async {
      await sql.run(
          text: 'SELECT big FROM users',
          confirmWrite: (_) async => fail('no confirm'));
      expect(
          sql.result!.rows.single.single, const WireBigInt('9007199254740993'));
      expect(sql.statusText, '1 row · 0.5 ms');
      expect(sql.resultsJson(), contains('9007199254740993'));
      expect(sql.entries.single.sql, 'SELECT big FROM users');
    });

    test('write: declined → not executed', () async {
      String? asked;
      await sql.run(
          text: 'DELETE FROM users',
          confirmWrite: (s) async {
            asked = s;
            return false;
          });
      expect(asked, 'DELETE FROM users');
      expect(sql.notice, 'Not executed.');
      expect(backend.calls(Methods.queryExecute), hasLength(1));
      expect(sql.entries, isEmpty);
    });

    test('write: confirmed → resent with allowWrite', () async {
      await sql.run(text: 'DELETE FROM users', confirmWrite: (_) async => true);
      final calls = backend.calls(Methods.queryExecute);
      expect(calls, hasLength(2));
      expect((jsonDecode(calls.last) as Map)['allowWrite'], isTrue);
      expect(sql.statusText, startsWith('2 rows affected'));
    });

    test('errors are shown and recorded as failed', () async {
      await sql.run(
          text: 'SELECT * FROM nope', confirmWrite: (_) async => false);
      expect(sql.error, 'QUERY_FAILED: no such table: nope');
      expect(sql.entries.single.succeeded, isFalse);
    });

    test('cancel stops waiting', () async {
      backend.sqlGate = Completer<void>();
      final run = sql.run(text: 'SELECT 1', confirmWrite: (_) async => false);
      await _settle();
      expect(sql.running, isTrue);
      sql.cancel();
      expect(sql.running, isFalse);
      expect(sql.notice, startsWith('Cancelled'));
      backend.sqlGate!.complete();
      await run;
      expect(sql.result, isNull);
    });
  });

  group('QueryHistory', () {
    test('persists, de-duplicates and filters by database', () {
      final storage = MemoryHistoryStorage();
      final history = QueryHistory(storage: storage);
      final at = DateTime(2024);
      history
        ..add(QueryHistoryEntry(sql: 'SELECT 1', databaseId: 'a', at: at))
        ..add(QueryHistoryEntry(sql: 'SELECT 2', databaseId: 'a', at: at))
        ..add(QueryHistoryEntry(sql: 'SELECT 1', databaseId: 'a', at: at))
        ..add(QueryHistoryEntry(sql: 'SELECT 1', databaseId: 'b', at: at));
      expect(
          history.forDatabase('a').map((e) => e.sql), ['SELECT 1', 'SELECT 2']);
      final restored = QueryHistory(storage: storage);
      expect(restored.entries, hasLength(3));
      restored.clear('a');
      expect(restored.entries.single.databaseId, 'b');
    });

    test('ignores corrupt storage', () {
      expect(QueryHistory(storage: MemoryHistoryStorage('{oops')).entries,
          isEmpty);
    });
  });

  group('InspectorController', () {
    test('loads databases on connect and selects entities', () async {
      final backend = FakeBackend();
      final connection = connectedSnapshot();
      final events = StreamController<void>.broadcast();
      final c = InspectorController(
        client: InspectorClient(backend),
        connection: connection,
        databasesChanged: events.stream,
        history: QueryHistory(storage: MemoryHistoryStorage()),
      );
      addTearDown(() {
        c.dispose();
        unawaited(events.close());
      });
      await _settle();
      expect(c.databases.map((d) => d.id), ['app', 'prefs']);
      expect(c.selectedDatabase!.id, 'app');
      expect(c.selectedDatabase!.overview!.entities, hasLength(2));
      final generation = c.generation;

      c.selectEntity('app', 'users');
      await _settle();
      expect(c.table!.page!.total, 60);
      expect(c.tab, InspectorTab.data);

      // SQL tab falls back when the database has no `sql` capability.
      c.setTab(InspectorTab.sql);
      c.selectDatabase('prefs');
      expect(c.tab, isNot(InspectorTab.sql));
      expect(c.table, isNull);

      // Hot restart: databasesChanged → reload, selection kept.
      c.selectEntity('app', 'users');
      await _settle();
      final table = c.table;
      events.add(null);
      await _settle();
      expect(c.generation, greaterThan(generation));
      expect(identical(c.table, table), isTrue);
      expect(c.selectedEntityName, 'users');

      // Reconnect after a disconnect reloads.
      final listCalls = backend.calls(Methods.databaseList).length;
      connection.value = ConnectionSnapshot.disconnected;
      connection.value = connectedSnapshot().value;
      await _settle();
      expect(backend.calls(Methods.databaseList).length, listCalls + 1);
    });

    test('sql controllers are kept per database', () {
      final c = InspectorController(
        client: InspectorClient(FakeBackend()),
        connection: ValueNotifier(ConnectionSnapshot.disconnected),
        databasesChanged: const Stream.empty(),
        history: QueryHistory(storage: MemoryHistoryStorage()),
      );
      addTearDown(c.dispose);
      final a = c.sqlController(_db())..sql = 'SELECT 1';
      expect(identical(c.sqlController(_db()), a), isTrue);
      expect(c.sqlController(_db()).sql, 'SELECT 1');
    });
  });

  group('ConnectionManager', () {
    test('follows the VM service source', () async {
      final source = _FakeSource();
      final manager = ConnectionManager(source: source)..start();
      addTearDown(manager.dispose);
      await _settle();
      expect(
          manager.snapshot.value.state, InspectorConnectionState.disconnected);
      expect(manager.snapshot.value.message,
          contains('Waiting for a running app'));
    });
  });
}

class _FakeSource implements VmServiceSource {
  final _changes = ChangeNotifier();

  @override
  Listenable get changes => _changes;

  @override
  String get label => 'test';

  @override
  VmService? get service => null;
}

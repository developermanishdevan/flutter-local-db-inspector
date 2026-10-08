@Tags(['e2e'])
library;

import 'dart:async';

import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:test/test.dart';

import 'support/demo_server.dart';

/// Client ↔ real Dart VM ↔ inspector runtime ↔ SQLite.
void main() {
  late DemoServer server;
  late InspectorConnection connection;
  late InspectorClient client;

  Future<ConnectionSnapshot> waitFor(
    bool Function(ConnectionSnapshot) predicate,
  ) async {
    if (predicate(connection.snapshot)) return connection.snapshot;
    return connection.onStateChanged
        .firstWhere(predicate)
        .timeout(const Duration(seconds: 60));
  }

  Future<List<DatabaseDescriptor>> waitForDatabases() async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      final dbs = await client.listDatabases();
      if (dbs.isNotEmpty) return dbs;
      if (DateTime.now().isAfter(deadline)) fail('no databases registered');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  setUpAll(() async {
    server = await DemoServer.start(restartable: true);
    connection = await InspectorConnection.connectUri(
      server.uri,
      label: 'demo',
      options: const InspectorConnectionOptions(
        rescanInterval: Duration(milliseconds: 250),
      ),
    );
    client = InspectorClient(connection);
    await waitFor((s) => s.isConnected);
  });

  tearDownAll(() async {
    await connection.dispose();
    await server.stop();
  });

  test('handshake reports protocol and limits', () {
    final status = connection.snapshot.status!;
    expect(status.protocolVersion, 1);
    expect(status.mode, InspectorMode.fullAccess);
    expect(status.limits.maxPageSize, 100);
    expect(status.methods, contains(Methods.valueRead));
  });

  test('database.list → schema.list → rows.query with search and sort',
      () async {
    final db = (await waitForDatabases()).single;
    expect(db.id, 'app_database');
    expect(db.dataModel, DbDataModel.relational);
    expect(db.capabilities, contains(DbCapability.sql));

    final schema = await client.schema(db.id);
    final counts = {for (final e in schema.entities) e.name: e.rowCount};
    expect(counts['users'], 1000);
    expect(counts['orders'], 10000);
    expect(
      schema.entities
          .any((e) => e.name == 'active_users' && e.kind == EntityKind.view),
      isTrue,
    );

    final table = await client.tableSchema(db.id, 'users');
    expect(table.schema.rowKey, isNot(RowKeyKind.none));
    expect(table.sensitiveColumns, {'password'});

    final page = await client.queryRows(
      db.id,
      'users',
      search: 'User 99',
      sort: const [RowSort(column: 'id', direction: SortDirection.desc)],
      pageSize: 5,
    );
    expect(page.total, 11);
    expect(page.rows, hasLength(5));
    final id = page.columns.indexWhere((c) => c.name == 'id');
    final pw = page.columns.indexWhere((c) => c.name == 'password');
    expect(page.rows.first.values[id], const WireInt(999));
    expect(page.rows.first.values[pw], const WireMasked());
    expect(page.rows.first.key, isNotNull);

    expect(
      await client.countRows(db.id, 'users', filters: const [
        RowFilter(column: 'email', operator: FilterOperator.isNull),
      ]),
      58, // every 17th user
    );

    final big = await client.queryRows(db.id, 'edge_cases', pageSize: 1);
    final bigIndex = big.columns.indexWhere((c) => c.name == 'big_int');
    expect(
        big.rows.single.values[bigIndex], const WireBigInt('9007199254740993'));
  });

  test('edit a cell and see it in the app database', () async {
    final page =
        await client.queryRows('app_database', 'users', filters: const [
      RowFilter(column: 'id', operator: FilterOperator.equals, value: 1),
    ]);
    final key = page.rows.single.key!;
    final result = await client.updateRow('app_database', 'users', key,
        {'name': const WireString('Edited from Dart')});
    expect(result.affectedRows, 1);
    final check = await client.executeSql(
        'app_database', 'SELECT name FROM users WHERE id = 1');
    expect(check.rows.single.single, const WireString('Edited from Dart'));
  });

  test('write SQL needs confirmation', () async {
    await expectLater(
      client.executeSql('app_database', 'DELETE FROM orders WHERE id = 1'),
      throwsA(isA<InspectorClientException>()
          .having((e) => e.requiresConfirmation, 'requiresConfirmation', true)),
    );
    final done = await client.executeSql(
      'app_database',
      'DELETE FROM orders WHERE id = 1',
      allowWrite: true,
    );
    expect(done.kind, SqlStatementKind.write);
    expect(done.affectedRows, 1);
  });

  test('insert and delete a row', () async {
    final inserted = await client.insertRow('app_database', 'products', {
      'name': const WireString('Inserted'),
      'price': const WireDouble(1.5),
      'stock': const WireInt(3),
      'created_at': const WireInt(0),
    });
    expect(inserted.affectedRows, 1);
    expect(inserted.insertedKey, isNotNull);
    final deleted = await client.deleteRow(
        'app_database', 'products', inserted.insertedKey!);
    expect(deleted.affectedRows, 1);
  });

  test('2 MB blob is streamed with value.read', () async {
    final page = await client.queryRows('app_database', 'edge_cases');
    final blobIndex = page.columns.indexWhere((c) => c.name == 'data');
    final cell = page.rows.first.values[blobIndex];
    expect(cell, isA<WireBlob>());
    expect((cell as WireBlob).size, 2 * 1024 * 1024);
    expect(WireValues.display(cell).text, 'BLOB 2.0 MB');
    final full = await client.readFullValue(
      'app_database',
      table: 'edge_cases',
      key: page.rows.first.key!,
      column: 'data',
    );
    expect(full.bytes.length, 2 * 1024 * 1024);
    expect(full.complete, isTrue);
    expect(full.bytes[1000], 1000 % 251);

    final textIndex = page.columns.indexWhere((c) => c.name == 'long_text');
    expect(page.rows.first.values[textIndex].isPartial, isTrue);
    final text = await client.readFullValue(
      'app_database',
      table: 'edge_cases',
      key: page.rows.first.key!,
      column: 'long_text',
    );
    expect(text.text, 'Lorem ipsum dolor sit amet. ' * 2000);
  });

  test('stats', () async {
    final stats = await client.stats('app_database');
    expect(stats.entities.map((e) => e.name), contains('orders'));
    expect(stats.indexCount, greaterThanOrEqualTo(1));
  });

  test('hot restart: reconnects automatically and reloads databases', () async {
    final before = connection.snapshot.isolateId;
    final reconnecting =
        waitFor((s) => s.state == InspectorConnectionState.reconnecting);
    final changed = connection.databasesChanged.first;
    server.restart();
    await reconnecting;
    final after = await waitFor((s) => s.isConnected);
    expect(after.isolateId, isNot(before));
    await changed.timeout(const Duration(seconds: 60));
    final dbs = await waitForDatabases();
    expect(dbs.single.id, 'app_database');
    // Fresh isolate, fresh in-memory database: the earlier edit is gone.
    final result = await client.executeSql(
        'app_database', 'SELECT name FROM users WHERE id = 1');
    expect(result.rows.single.single, const WireString('User 1'));
  });

  test('requests made during a restart wait for the app to come back',
      () async {
    final reconnecting =
        waitFor((s) => s.state == InspectorConnectionState.reconnecting);
    server.restart();
    await reconnecting;
    final dbs = await client.listDatabases();
    expect(dbs, isA<List<DatabaseDescriptor>>());
    expect(connection.isConnected, isTrue);
  });

  test('stopping the app disconnects', () async {
    final disconnected =
        waitFor((s) => s.state == InspectorConnectionState.disconnected);
    await server.stop();
    await disconnected;
    await expectLater(
      client.listDatabases(),
      throwsA(isA<InspectorClientException>()
          .having((e) => e.code, 'code', ClientErrorCodes.notConnected)),
    );
  });
}

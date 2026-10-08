import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

import { ConnectionManager, type ConnectionSnapshot } from '../../src/connection/connectionManager';
import { WebSocketTransport } from '../../src/connection/wsTransport';
import { InspectorClient } from '../../src/services/inspectorClient';
import { exportEntity } from '../../src/services/exporter';
import { ErrorCodes, InspectorError } from '../../src/protocol/types';
import { DemoServer } from './demoServer';

function waitForState(
  manager: ConnectionManager,
  predicate: (s: ConnectionSnapshot) => boolean,
  timeoutMs = 60_000,
): Promise<ConnectionSnapshot> {
  if (predicate(manager.snapshot)) return Promise.resolve(manager.snapshot);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      sub.dispose();
      reject(new Error(`state not reached; last: ${JSON.stringify(manager.snapshot)}`));
    }, timeoutMs);
    const sub = manager.onDidChangeState((s) => {
      if (predicate(s)) {
        clearTimeout(timer);
        sub.dispose();
        resolve(s);
      }
    });
  });
}

async function waitForDatabases(client: InspectorClient, timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const dbs = await client.listDatabases();
    if (dbs.length > 0) return dbs;
    if (Date.now() > deadline) throw new Error('no databases registered');
    await new Promise((r) => setTimeout(r, 250));
  }
}

describe('VS Code client ↔ real Dart VM', () => {
  let server: DemoServer;
  let manager: ConnectionManager;
  let client: InspectorClient;

  before(async () => {
    server = await DemoServer.start({ restartable: true });
    manager = new ConnectionManager({ rescanIntervalMs: 250 });
    client = new InspectorClient(manager);
    await manager.connect({
      id: server.uri,
      label: 'demo',
      createTransport: () => WebSocketTransport.connect(server.uri),
    });
    await waitForState(manager, (s) => s.state === 'connected');
  });

  after(async () => {
    manager.dispose();
    await server.stop();
  });

  test('handshake reports protocol and limits', () => {
    const status = manager.snapshot.status!;
    assert.equal(status.protocolVersion, 1);
    assert.equal(status.mode, 'fullAccess');
    assert.equal(status.limits.maxPageSize, 100);
  });

  test('database.list → schema.list → rows.query', async () => {
    const [db] = await waitForDatabases(client);
    assert.equal(db.id, 'app_database');
    assert.equal(db.dataModel, 'relational');
    assert.ok(db.capabilities.includes('sql'));

    const schema = await client.schema(db.id);
    const counts = Object.fromEntries(schema.entities.map((e) => [e.name, e.rowCount]));
    assert.equal(counts.users, 1000);
    assert.equal(counts.orders, 10000);
    assert.ok(schema.entities.some((e) => e.name === 'active_users' && e.kind === 'view'));

    const page = await client.queryRows({
      databaseId: db.id,
      table: 'users',
      search: 'User 99',
      sort: [{ column: 'id', direction: 'desc' }],
      pageSize: 5,
    });
    assert.equal(page.total, 11);
    assert.equal(page.rows.length, 5);
    assert.deepEqual(page.rows[0].key, { rowid: 999 });
    const pw = page.columns.findIndex((c) => c.name === 'password');
    assert.deepEqual(page.rows[0].values[pw], { $type: 'masked' });
  });

  test('edit a cell and see it in the app database', async () => {
    await client.updateRow('app_database', 'users', { rowid: 1 }, { name: 'Edited from VS Code' });
    const result = await client.executeSql('app_database', 'SELECT name FROM users WHERE id = 1');
    assert.deepEqual(result.rows, [['Edited from VS Code']]);
  });

  test('write SQL needs confirmation', async () => {
    await assert.rejects(
      client.executeSql('app_database', 'DELETE FROM orders WHERE id = 1'),
      (e: unknown) => e instanceof InspectorError && e.requiresConfirmation,
    );
    const done = await client.executeSql('app_database', 'DELETE FROM orders WHERE id = 1', { allowWrite: true });
    assert.equal(done.affectedRows, 1);
  });

  test('large blob is streamed with value.read', async () => {
    const page = await client.queryRows({ databaseId: 'app_database', table: 'edge_cases' });
    const blobIndex = page.columns.findIndex((c) => c.name === 'data');
    const cell = page.rows[0].values[blobIndex] as { $type: string; size: number };
    assert.equal(cell.$type, 'blob');
    assert.equal(cell.size, 2 * 1024 * 1024);
    const full = await client.readFullValue('app_database', { table: 'edge_cases', key: page.rows[0].key!, column: 'data' });
    assert.equal(full.bytes.length, 2 * 1024 * 1024);
    assert.equal(full.bytes[1000], 1000 % 251);
  });

  test('export streams a table to CSV', async () => {
    let csv = '';
    const summary = await exportEntity(client, {
      databaseId: 'app_database',
      table: 'products',
      format: 'csv',
      write: async (chunk) => {
        csv += chunk;
      },
    });
    assert.equal(summary.rows, 5000);
    assert.equal(csv.trim().split('\r\n').length, 5001);
  });

  test('hot restart: reconnects automatically and reloads databases', async () => {
    const before = manager.snapshot.isolateId;
    const reconnecting = waitForState(manager, (s) => s.state === 'reconnecting');
    server.restart();
    await reconnecting;
    const after = await waitForState(manager, (s) => s.state === 'connected');
    assert.notEqual(after.isolateId, before);
    const dbs = await waitForDatabases(client);
    assert.equal(dbs[0].id, 'app_database');
    // Fresh isolate, fresh in-memory database: the earlier edit is gone.
    const result = await client.executeSql('app_database', 'SELECT name FROM users WHERE id = 1');
    assert.deepEqual(result.rows, [['User 1']]);
  });

  test('requests made during a restart wait for the app to come back', async () => {
    server.restart();
    await waitForState(manager, (s) => s.state === 'reconnecting');
    const dbs = await client.listDatabases();
    assert.ok(Array.isArray(dbs));
  });

  test('stopping the app disconnects', async () => {
    const disconnected = waitForState(manager, (s) => s.state === 'disconnected');
    await server.stop();
    await disconnected;
    await assert.rejects(client.listDatabases(), (e: unknown) => e instanceof InspectorError && e.code === ErrorCodes.notConnected);
  });
});

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { QueryStore, type KeyValueMemento } from '../../src/services/queryStore';

class MemoryMemento implements KeyValueMemento {
  private data = new Map<string, unknown>();
  get<T>(key: string, fallback: T): T {
    return (this.data.get(key) as T | undefined) ?? fallback;
  }
  async update(key: string, value: unknown): Promise<void> {
    this.data.set(key, value);
  }
}

test('history is bounded, newest first and de-duplicated', async () => {
  const store = new QueryStore(new MemoryMemento(), () => 3);
  for (const sql of ['SELECT 1', 'SELECT 2', 'SELECT 1', 'SELECT 3', 'SELECT 4']) {
    await store.record({ sql, databaseId: 'main', databaseName: 'main', ok: true });
  }
  assert.deepEqual(store.history.map((h) => h.sql), ['SELECT 4', 'SELECT 3', 'SELECT 1']);
  await store.deleteHistory(store.history[0].id);
  assert.equal(store.history.length, 2);
  await store.clearHistory();
  assert.equal(store.history.length, 0);
});

test('saved queries are kept per app and sorted by name', async () => {
  const store = new QueryStore(new MemoryMemento(), () => 10);
  let changes = 0;
  store.onDidChange(() => changes++);
  await store.save('sfa_app', 'Recent Orders', 'SELECT * FROM orders');
  await store.save('sfa_app', 'Active Users', 'SELECT * FROM users WHERE is_active = 1');
  await store.save('other_app', 'Prefs', 'SELECT 1', 'sqlite');
  assert.deepEqual(store.saved('sfa_app').map((q) => q.name), ['Active Users', 'Recent Orders']);
  assert.deepEqual(store.saved('other_app').map((q) => q.name), ['Prefs']);
  assert.deepEqual(store.saved('unknown'), []);
  await store.deleteSaved('sfa_app', store.saved('sfa_app')[0].id);
  assert.deepEqual(store.saved('sfa_app').map((q) => q.name), ['Recent Orders']);
  assert.equal(changes, 4);
});

test('saving under an existing name replaces that query', async () => {
  const store = new QueryStore(new MemoryMemento(), () => 10);
  const first = await store.save('sfa_app', 'Orders', 'SELECT * FROM orders');
  const second = await store.save('sfa_app', ' orders ', 'SELECT id FROM orders', 'drift');
  assert.equal(second.id, first.id);
  assert.equal(store.saved('sfa_app').length, 1);
  assert.equal(store.saved('sfa_app')[0].sql, 'SELECT id FROM orders');
  assert.equal(store.saved('sfa_app')[0].databaseType, 'drift');
  assert.ok(store.saved('sfa_app')[0].updatedAt);
});

test('groups list every app, the current one first; empty apps disappear', async () => {
  const store = new QueryStore(new MemoryMemento(), () => 10);
  await store.save('b_app', 'B', 'SELECT 2');
  await store.save('a_app', 'A', 'SELECT 1');
  await store.save('c_app', 'C', 'SELECT 3');
  assert.deepEqual(store.savedGroups('c_app').map((g) => g.app), ['c_app', 'a_app', 'b_app']);
  await store.deleteSaved('a_app', store.saved('a_app')[0].id);
  assert.deepEqual(store.savedGroups().map((g) => g.app), ['b_app', 'c_app']);
});

test('saved queries live in their own (global) storage, history in the workspace', async () => {
  const workspace = new MemoryMemento();
  const global = new MemoryMemento();
  const store = new QueryStore(workspace, () => 10, global);
  await store.save('sfa_app', 'Q', 'SELECT 1');
  await store.record({ sql: 'SELECT 1', databaseId: 'a', databaseName: 'a', ok: true });
  // A new workspace (another QueryStore on the same global storage) still sees the saved query.
  const elsewhere = new QueryStore(new MemoryMemento(), () => 10, global);
  assert.deepEqual(elsewhere.saved('sfa_app').map((q) => q.name), ['Q']);
  assert.equal(elsewhere.history.length, 0);
});

test('1.x saved queries move to the first connected app once', async () => {
  const workspace = new MemoryMemento();
  await workspace.update('flutterDbInspector.savedQueries', [
    { id: 'old1', name: 'Legacy', sql: 'SELECT 1', createdAt: 1 },
    { id: 'old2', name: 'Kept', sql: 'SELECT 2', createdAt: 1 },
  ]);
  const store = new QueryStore(workspace, () => 10, new MemoryMemento());
  await store.save('sfa_app', 'kept', 'SELECT 99');
  await store.adoptLegacySaved('sfa_app');
  assert.deepEqual(store.saved('sfa_app').map((q) => [q.name, q.sql]), [['kept', 'SELECT 99'], ['Legacy', 'SELECT 1']]);
  await store.adoptLegacySaved('other_app');
  assert.deepEqual(store.saved('other_app'), []);
});

test('history can be disabled', async () => {
  const store = new QueryStore(new MemoryMemento(), () => 0);
  await store.record({ sql: 'SELECT 1', databaseId: 'a', databaseName: 'a', ok: true });
  assert.equal(store.history.length, 0);
});

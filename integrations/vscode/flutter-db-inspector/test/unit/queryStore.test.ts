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

test('saved queries are sorted by name', async () => {
  const store = new QueryStore(new MemoryMemento(), () => 10);
  let changes = 0;
  store.onDidChange(() => changes++);
  await store.save('Recent Orders', 'SELECT * FROM orders');
  await store.save('Active Users', 'SELECT * FROM users WHERE is_active = 1');
  assert.deepEqual(store.saved.map((q) => q.name), ['Active Users', 'Recent Orders']);
  await store.deleteSaved(store.saved[0].id);
  assert.deepEqual(store.saved.map((q) => q.name), ['Recent Orders']);
  assert.equal(changes, 3);
});

test('history can be disabled', async () => {
  const store = new QueryStore(new MemoryMemento(), () => 0);
  await store.record({ sql: 'SELECT 1', databaseId: 'a', databaseName: 'a', ok: true });
  assert.equal(store.history.length, 0);
});

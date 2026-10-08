/**
 * Real Flutter app end-to-end test (opt-in, needs a device):
 *
 *   FDI_FLUTTER_DEVICE=macos npm run test:integration
 *
 * Runs examples/sqlite_example with `flutter run --machine`, connects through
 * the extension's connection layer, edits data, hot-restarts the app and
 * checks the inspector reconnects on its own.
 */
import assert from 'node:assert/strict';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import * as path from 'node:path';
import * as readline from 'node:readline';
import { after, before, describe, test } from 'node:test';

import { ConnectionManager, type ConnectionSnapshot } from '../../src/connection/connectionManager';
import { WebSocketTransport } from '../../src/connection/wsTransport';
import { InspectorClient } from '../../src/services/inspectorClient';
import { repoRoot } from './demoServer';

const device = process.env.FDI_FLUTTER_DEVICE;

class FlutterRun {
  private nextId = 1;
  private appId?: string;
  private readonly waiters: { event: string; resolve(params: Record<string, unknown>): void }[] = [];

  constructor(private readonly child: ChildProcessWithoutNullStreams) {
    readline.createInterface({ input: child.stdout }).on('line', (line) => {
      if (!line.startsWith('[{')) return;
      for (const message of JSON.parse(line) as { event?: string; params?: Record<string, unknown> }[]) {
        if (message.event === 'app.start') this.appId = message.params?.appId as string;
        for (const w of [...this.waiters]) {
          if (w.event === message.event) {
            this.waiters.splice(this.waiters.indexOf(w), 1);
            w.resolve(message.params ?? {});
          }
        }
      }
    });
    child.stderr.on('data', (d: Buffer) => process.stderr.write(d));
  }

  static start(deviceId: string): FlutterRun {
    const cwd = path.join(repoRoot, 'examples', 'sqlite_example');
    return new FlutterRun(spawn('flutter', ['run', '--machine', '-d', deviceId], { cwd }));
  }

  waitFor(event: string, timeoutMs = 600_000): Promise<Record<string, unknown>> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timed out waiting for ${event}`)), timeoutMs);
      this.waiters.push({
        event,
        resolve: (p) => {
          clearTimeout(timer);
          resolve(p);
        },
      });
    });
  }

  private send(method: string, params: Record<string, unknown>): void {
    this.child.stdin.write(`${JSON.stringify([{ id: this.nextId++, method, params }])}\n`);
  }

  hotRestart(): void {
    this.send('app.restart', { appId: this.appId, fullRestart: true, pause: false });
  }

  async stop(): Promise<void> {
    if (this.child.exitCode !== null) return;
    const exited = new Promise((r) => this.child.once('exit', r));
    this.send('app.stop', { appId: this.appId });
    const timer = setTimeout(() => this.child.kill(), 20_000);
    await exited;
    clearTimeout(timer);
  }
}

function waitForState(manager: ConnectionManager, state: string, timeoutMs = 60_000): Promise<ConnectionSnapshot> {
  if (manager.snapshot.state === state) return Promise.resolve(manager.snapshot);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`no ${state}; last ${JSON.stringify(manager.snapshot)}`)), timeoutMs);
    const sub = manager.onDidChangeState((s) => {
      if (s.state === state) {
        clearTimeout(timer);
        sub.dispose();
        resolve(s);
      }
    });
  });
}

async function databases(client: InspectorClient, expected: number) {
  for (let i = 0; i < 240; i++) {
    const list = await client.listDatabases();
    if (list.length >= expected) return list;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error('databases were not registered');
}

describe('real Flutter app', { skip: device ? false : 'set FDI_FLUTTER_DEVICE to run' }, () => {
  let app: FlutterRun;
  let manager: ConnectionManager;
  let client: InspectorClient;

  before(async () => {
    app = FlutterRun.start(device!);
    const { wsUri } = await app.waitFor('app.debugPort');
    manager = new ConnectionManager({ rescanIntervalMs: 250 });
    client = new InspectorClient(manager);
    await manager.connect({ id: 'flutter', label: 'sqlite_example', createTransport: () => WebSocketTransport.connect(wsUri as string) });
    await waitForState(manager, 'connected', 120_000);
  });

  after(async () => {
    manager?.dispose();
    await app?.stop();
  });

  test('lists every engine with its own data model', async () => {
    const list = await databases(client, 3);
    const byId = Object.fromEntries(list.map((d) => [d.id, d]));
    assert.equal(byId.app_database.dataModel, 'relational');
    assert.equal(byId.cache.dataModel, 'keyValue');
    assert.equal(byId.preferences.dataModel, 'keyValue');
    assert.ok(byId.app_database.capabilities.includes('sql'));
    assert.ok(!byId.cache.capabilities.includes('sql'));
  });

  test('browses tables, boxes and preferences', async () => {
    const schema = await client.schema('app_database');
    const counts = Object.fromEntries(schema.entities.map((e) => [e.name, e.rowCount]));
    assert.ok((counts.users ?? 0) >= 1000);
    assert.equal(counts.products, 5000);
    assert.equal(counts.orders, 10000);

    const users = await client.queryRows({ databaseId: 'app_database', table: 'users', search: 'Zoë', pageSize: 5 });
    assert.ok((users.total ?? 0) >= 100);
    const phone = users.columns.findIndex((c) => c.name === 'phone');
    assert.deepEqual(users.rows[0].values[phone], { $type: 'masked' });

    const cache = await client.queryRows({ databaseId: 'cache', table: 'cache' });
    assert.ok(cache.rows.some((r) => r.values[0] === 'feature_flags'));
    const prefs = await client.queryRows({ databaseId: 'preferences', table: 'shared_preferences' });
    assert.ok(prefs.rows.some((r) => r.values[0] === 'launch_count'));
  });

  test('edits are written to the app database', async () => {
    await client.updateRow('app_database', 'settings', { rowid: 1 }, { value: 'light' });
    const result = await client.executeSql('app_database', "SELECT value FROM settings WHERE key = 'theme'");
    assert.deepEqual(result.rows, [['light']]);
  });

  test('hot restart: the inspector reconnects automatically', async () => {
    const before = manager.snapshot.isolateId;
    const reconnecting = waitForState(manager, 'reconnecting', 60_000);
    app.hotRestart();
    await reconnecting;
    const after = await waitForState(manager, 'connected', 120_000);
    assert.notEqual(after.isolateId, before);
    const list = await databases(client, 3);
    assert.equal(list.length, 3);
    // The database file persists across restarts, so the earlier edit is still there.
    const result = await client.executeSql('app_database', "SELECT value FROM settings WHERE key = 'theme'");
    assert.deepEqual(result.rows, [['light']]);
  });
});

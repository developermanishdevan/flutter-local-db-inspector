import assert from 'node:assert/strict';
import * as vscode from 'vscode';

import type { FlutterDbInspectorApi } from '../../../src/extension';
// Type-only: the extension runs from its esbuild bundle, so class identity differs.
import type { DatabaseNode, EntityNode, GroupNode, TreeNode } from '../../../src/providers/databaseTree';
import { DemoServer } from '../../integration/demoServer';

type Test = { name: string; fn: () => Promise<void> };
const tests: Test[] = [];
const it = (name: string, fn: () => Promise<void>) => tests.push({ name, fn });

async function until<T>(what: string, probe: () => T | undefined | Promise<T | undefined>, timeoutMs = 60_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await probe();
    if (value !== undefined && value !== false) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what} (open tabs: ${tabLabels().join(' | ')})`);
    await new Promise((r) => setTimeout(r, 200));
  }
}

function tabLabels(): string[] {
  return vscode.window.tabGroups.all.flatMap((g) => g.tabs.map((t) => t.label));
}

let server: DemoServer;
let api: FlutterDbInspectorApi;

it('activates and contributes its commands', async () => {
  const ext = vscode.extensions.getExtension<FlutterDbInspectorApi>('flutter-db-inspector.flutter-db-inspector');
  assert.ok(ext, 'extension found');
  api = await ext.activate();
  const commands = await vscode.commands.getCommands(true);
  for (const id of ['openInspector', 'refresh', 'runQuery', 'exportDatabase', 'connect', 'disconnect']) {
    assert.ok(commands.includes(`flutterDbInspector.${id}`), id);
  }
});

it('connects to a running app and lists its database', async () => {
  await vscode.commands.executeCommand('flutterDbInspector.connect', server.uri);
  await until('connected', () => api.manager.isConnected || undefined);
  const databases = await until('databases in the tree', () => (api.tree.current.length ? api.tree.current : undefined));
  assert.equal(databases[0].id, 'app_database');
});

it('shows tables and views in the tree, grouped by kind', async () => {
  const [db] = (await api.tree.getChildren()) as DatabaseNode[];
  assert.equal(db.kind, 'database');
  const item = api.tree.getTreeItem(db);
  assert.equal(item.label, 'app_database');
  assert.match(String(item.contextValue), /^database.*:sql/);
  const groups = (await api.tree.getChildren(db)) as GroupNode[];
  assert.deepEqual(groups.map((g) => g.label), ['Tables', 'Views', 'Indexes']);
  const tables = groups[0].children as EntityNode[];
  const users = tables.find((t) => t.entity.name === 'users')!;
  assert.equal(api.tree.getTreeItem(users).description, '1,000');
});

it('opens the data grid, schema and SQL console panels', async () => {
  const [db] = (await api.tree.getChildren()) as TreeNode[];
  const groups = (await api.tree.getChildren(db)) as GroupNode[];
  const users = (groups[0].children as EntityNode[]).find((t) => t.entity.name === 'users')!;
  await vscode.commands.executeCommand('flutterDbInspector.openTable', users);
  await until('users panel', () => tabLabels().includes('users — app_database') || undefined);
  await vscode.commands.executeCommand('flutterDbInspector.openSqlConsole', db);
  await until('SQL panel', () => tabLabels().includes('SQL — app_database') || undefined);
  await vscode.commands.executeCommand('flutterDbInspector.showStatistics', db);
  await until('stats panel', () => tabLabels().includes('Statistics — app_database') || undefined);

  // Each webview booted, asked the host for its data and raised no errors.
  for (const [key, minRequests] of [['table:app_database:users', 2], ['stats:app_database', 1], ['sql:app_database', 0]] as const) {
    const d = await until(`${key} ready`, () => {
      const diag = api.panels.diagnostics(key);
      return diag?.ready && diag.requests >= minRequests ? diag : undefined;
    });
    assert.deepEqual(d.errors, [], key);
  }
});

it('runs SQL through the console path', async () => {
  const db = api.tree.current[0];
  const read = (await api.panels.runSql(db, 'SELECT COUNT(*) AS n FROM orders')) as { rows: unknown[][] };
  assert.deepEqual(read.rows, [[10000]]);
});

it('filters the tree by table name (and clears it)', async () => {
  api.tree.setFilter('ORD');
  const [db] = (await api.tree.getChildren()) as TreeNode[];
  const groups = (await api.tree.getChildren(db)) as GroupNode[];
  const names = groups.flatMap((g) =>
    g.children.map((c) => (c as EntityNode).entity?.name ?? (c as { index?: { name: string } }).index?.name),
  );
  assert.deepEqual(names, ['orders', 'idx_orders_user']);
  const item = api.tree.getTreeItem(groups[0].children[0] as EntityNode);
  assert.deepEqual((item.label as vscode.TreeItemLabel).highlights, [[0, 3]]);

  api.tree.setFilter('nothing-like-this');
  const none = await api.tree.getChildren(db);
  assert.match(String(api.tree.getTreeItem(none[0]).label), /No names match/);

  await vscode.commands.executeCommand('flutterDbInspector.clearFilter');
  const all = (await api.tree.getChildren(db)) as GroupNode[];
  assert.ok(all[0].children.length >= 4);
});

it('edits through the extension reach the app database', async () => {
  await api.client.updateRow('app_database', 'users', { rowid: 1 }, { name: 'Edited in VS Code' });
  const result = await api.client.executeSql('app_database', 'SELECT name FROM users WHERE id = 1');
  assert.deepEqual(result.rows, [['Edited in VS Code']]);
});

it('disconnects', async () => {
  await vscode.commands.executeCommand('flutterDbInspector.disconnect');
  assert.equal(api.manager.snapshot.state, 'disconnected');
  await until('tree cleared', () => (api.tree.current.length === 0 ? true : undefined));
});

/** Entry point called by the VS Code test runner. */
export async function run(): Promise<void> {
  server = await DemoServer.start();
  const failures: string[] = [];
  try {
    for (const t of tests) {
      try {
        await t.fn();
        console.log(`  ✔ ${t.name}`);
      } catch (error) {
        console.log(`  ✖ ${t.name}\n    ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
        failures.push(t.name);
      }
    }
  } finally {
    await server.stop();
  }
  console.log(`\n${tests.length - failures.length} passed, ${failures.length} failed`);
  if (failures.length) throw new Error(`${failures.length} VS Code test(s) failed`);
}

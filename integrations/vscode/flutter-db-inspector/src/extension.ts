import * as vscode from 'vscode';

import { registerCommands } from './commands';
import { ConnectionManager } from './connection/connectionManager';
import { DebugSessionWatcher } from './connection/sessionWatcher';
import { PanelManager } from './panels/panelManager';
import { DatabaseTreeProvider } from './providers/databaseTree';
import { QueriesTreeProvider } from './providers/queriesTree';
import { ConnectionStatusBar } from './providers/statusBar';
import { InspectorClient } from './services/inspectorClient';
import { QueryStore } from './services/queryStore';

// Flutter DB Inspector for VS Code. VS Code never touches database files: it
// talks to the running app through the Dart VM service, using the same
// protocol as DevTools and Android Studio.

/** Returned from `activate` for integration tests and other extensions. */
export interface FlutterDbInspectorApi {
  readonly manager: ConnectionManager;
  readonly client: InspectorClient;
  readonly tree: DatabaseTreeProvider;
  readonly panels: PanelManager;
}

export function activate(context: vscode.ExtensionContext): FlutterDbInspectorApi {
  const output = vscode.window.createOutputChannel('Flutter DB Inspector', { log: true });
  const log = (message: string) => output.info(message);
  const config = () => vscode.workspace.getConfiguration('flutterDbInspector');

  const manager = new ConnectionManager({
    requestTimeoutMs: config().get('requestTimeoutMs', 30_000),
    log,
  });
  const client = new InspectorClient(manager);
  const queries = new QueryStore(context.workspaceState, () => config().get('historyLimit', 100));
  const tree = new DatabaseTreeProvider(client, manager);
  const statusBar = new ConnectionStatusBar();

  const treeView = vscode.window.createTreeView('flutterDbInspector.databases', {
    treeDataProvider: tree,
    showCollapseAll: true,
  });
  const queriesView = vscode.window.createTreeView('flutterDbInspector.queries', {
    treeDataProvider: new QueriesTreeProvider(queries),
  });

  let refreshTimer: NodeJS.Timeout | undefined;
  const panels = new PanelManager(context.extensionUri, client, manager, queries, {
    log,
    onDataChanged: (databaseId) => {
      // Debounced: row counts in the tree follow edits made from any panel.
      if (refreshTimer) clearTimeout(refreshTimer);
      refreshTimer = setTimeout(() => tree.invalidate(databaseId), 500);
    },
    exportTable: async (database, table) =>
      void await vscode.commands.executeCommand('flutterDbInspector.exportTable', { database, entity: { name: table, kind: 'table' } }),
    settings: () => ({
      pageSize: config().get('defaultPageSize', 50),
      confirmCellEdits: config().get('confirmCellEdits', false),
    }),
  });

  const refresh = async () => {
    await tree.refresh();
    statusBar.update(manager.snapshot, tree.current.length);
    panels.refreshAll(tree.current);
  };

  const describeState = () => {
    const s = manager.snapshot;
    void vscode.commands.executeCommand('setContext', 'flutterDbInspector.connected', s.state === 'connected');
    statusBar.update(s, tree.current.length);
    switch (s.state) {
      case 'connected':
        treeView.description = `● ${s.target?.label ?? 'Connected'}${tree.filter ? ` · filter: "${tree.filter}"` : ''}`;
        treeView.message = s.status?.mode === 'readOnly' ? 'Read-only mode: editing is disabled by the app.' : undefined;
        break;
      case 'connecting':
      case 'reconnecting':
        treeView.description = s.state === 'connecting' ? 'Connecting…' : 'Reconnecting…';
        treeView.message = s.message;
        break;
      case 'error':
        treeView.description = 'Error';
        treeView.message = s.message;
        break;
      default:
        treeView.description = undefined;
        treeView.message = undefined;
    }
  };

  context.subscriptions.push(tree.onDidChangeTreeData(() => describeState()));
  manager.onDidChangeState((s) => {
    describeState();
    if (s.state === 'disconnected' || s.state === 'error') void tree.refresh();
  });
  // Fired after (re)connecting and when the app registers databases.
  manager.onDidChangeDatabases(() => void refresh());

  const watcher = new DebugSessionWatcher(manager, log, () => config().get('autoConnect', true));

  registerCommands(context, { client, manager, watcher, tree, panels, queries, refresh, log });

  context.subscriptions.push(
    output,
    statusBar,
    treeView,
    queriesView,
    panels,
    watcher,
    { dispose: () => manager.dispose() },
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('flutterDbInspector.requestTimeoutMs')) {
        manager.updateOptions({ requestTimeoutMs: config().get('requestTimeoutMs', 30_000) });
      }
    }),
  );
  describeState();
  return { manager, client, tree, panels };
}

export function deactivate(): void {}

import * as vscode from 'vscode';

import { relativeTime } from '../protocol/values';
import type { HistoryEntry, QueryStore, SavedQuery } from '../services/queryStore';

export type QueryNode =
  | { kind: 'group'; label: 'Saved'; app: string }
  | { kind: 'group'; label: 'History' }
  | { kind: 'saved'; app: string; query: SavedQuery }
  | { kind: 'history'; entry: HistoryEntry };

/**
 * Saved queries, one group per app (Dart package name), and query history.
 * Kept in VS Code, not in the app. The connected app's group comes first and
 * is expanded; other apps' queries stay listed until they are deleted.
 */
export class QueriesTreeProvider implements vscode.TreeDataProvider<QueryNode> {
  private readonly changed = new vscode.EventEmitter<QueryNode | undefined>();
  readonly onDidChangeTreeData = this.changed.event;

  constructor(
    private readonly store: QueryStore,
    private readonly currentApp: () => string | undefined,
  ) {
    store.onDidChange(() => this.changed.fire(undefined));
  }

  refresh(): void {
    this.changed.fire(undefined);
  }

  getTreeItem(node: QueryNode): vscode.TreeItem {
    switch (node.kind) {
      case 'group': {
        if (node.label === 'Saved') {
          const current = node.app === this.currentApp();
          const item = new vscode.TreeItem(
            `Saved · ${node.app}`,
            current ? vscode.TreeItemCollapsibleState.Expanded : vscode.TreeItemCollapsibleState.Collapsed,
          );
          item.id = `saved:${node.app}:${current}`;
          item.description = `${this.store.saved(node.app).length}${current ? ' · this app' : ''}`;
          item.tooltip = `Saved queries of the app "${node.app}"`;
          item.iconPath = new vscode.ThemeIcon('star-full');
          return item;
        }
        const item = new vscode.TreeItem(node.label, vscode.TreeItemCollapsibleState.Expanded);
        item.description = String(this.store.history.length);
        item.iconPath = new vscode.ThemeIcon('history');
        return item;
      }
      case 'saved': {
        const item = new vscode.TreeItem(node.query.name);
        item.description = firstLine(node.query.sql);
        item.tooltip = new vscode.MarkdownString().appendCodeblock(node.query.sql, 'sql');
        item.iconPath = new vscode.ThemeIcon('star-full');
        item.contextValue = 'query.saved';
        item.command = { command: 'flutterDbInspector.query.open', title: 'Open', arguments: [node] };
        return item;
      }
      case 'history': {
        const { entry } = node;
        const item = new vscode.TreeItem(firstLine(entry.sql));
        item.description = `${relativeTime(entry.at)} · ${entry.databaseName}`;
        item.tooltip = new vscode.MarkdownString()
          .appendCodeblock(entry.sql, 'sql')
          .appendMarkdown(
            `\n${entry.ok ? '✓' : '✗'} ${new Date(entry.at).toLocaleString()}` +
              (entry.elapsedMs === undefined ? '' : ` · ${entry.elapsedMs.toFixed(1)} ms`) +
              (entry.rowCount === undefined ? '' : ` · ${entry.rowCount} rows`),
          );
        item.iconPath = new vscode.ThemeIcon(entry.ok ? 'pass' : 'error');
        item.contextValue = 'query.history';
        item.command = { command: 'flutterDbInspector.query.open', title: 'Open', arguments: [node] };
        return item;
      }
    }
  }

  getChildren(node?: QueryNode): QueryNode[] {
    if (!node) {
      const groups: QueryNode[] = this.store
        .savedGroups(this.currentApp())
        .map((g) => ({ kind: 'group', label: 'Saved', app: g.app }));
      if (this.store.history.length > 0) groups.push({ kind: 'group', label: 'History' });
      return groups;
    }
    if (node.kind !== 'group') return [];
    if (node.label === 'Saved') {
      const app = node.app;
      return this.store.saved(app).map((query) => ({ kind: 'saved', app, query }));
    }
    return this.store.history.map((entry) => ({ kind: 'history', entry }));
  }
}

function firstLine(sql: string): string {
  const line = sql.replace(/\s+/g, ' ').trim();
  return line.length > 80 ? `${line.slice(0, 80)}…` : line;
}

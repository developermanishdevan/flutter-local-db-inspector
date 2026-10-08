import * as vscode from 'vscode';

import { relativeTime } from '../protocol/values';
import type { HistoryEntry, QueryStore, SavedQuery } from '../services/queryStore';

export type QueryNode =
  | { kind: 'group'; label: 'Saved' | 'History' }
  | { kind: 'saved'; query: SavedQuery }
  | { kind: 'history'; entry: HistoryEntry };

/** Saved queries and query history (kept in VS Code, not in the app). */
export class QueriesTreeProvider implements vscode.TreeDataProvider<QueryNode> {
  private readonly changed = new vscode.EventEmitter<QueryNode | undefined>();
  readonly onDidChangeTreeData = this.changed.event;

  constructor(private readonly store: QueryStore) {
    store.onDidChange(() => this.changed.fire(undefined));
  }

  refresh(): void {
    this.changed.fire(undefined);
  }

  getTreeItem(node: QueryNode): vscode.TreeItem {
    switch (node.kind) {
      case 'group': {
        const count = node.label === 'Saved' ? this.store.saved.length : this.store.history.length;
        const item = new vscode.TreeItem(node.label, vscode.TreeItemCollapsibleState.Expanded);
        item.description = String(count);
        item.iconPath = new vscode.ThemeIcon(node.label === 'Saved' ? 'star-full' : 'history');
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
      const groups: QueryNode[] = [];
      if (this.store.saved.length > 0) groups.push({ kind: 'group', label: 'Saved' });
      if (this.store.history.length > 0) groups.push({ kind: 'group', label: 'History' });
      return groups;
    }
    if (node.kind !== 'group') return [];
    return node.label === 'Saved'
      ? this.store.saved.map((query) => ({ kind: 'saved', query }))
      : this.store.history.map((entry) => ({ kind: 'history', entry }));
  }
}

function firstLine(sql: string): string {
  const line = sql.replace(/\s+/g, ' ').trim();
  return line.length > 80 ? `${line.slice(0, 80)}…` : line;
}

import * as vscode from 'vscode';

import type { ConnectionManager } from '../connection/connectionManager';
import type {
  DatabaseDescriptor,
  EntitySummary,
  IndexInfo,
  SchemaOverview,
  TriggerInfo,
} from '../protocol/types';
import { formatCount } from '../protocol/values';
import type { InspectorClient } from '../services/inspectorClient';
import { dataModelLabel, engineLabel, entityGroupLabel, entityIcon, recordNoun } from './labels';

export type TreeNode = DatabaseNode | GroupNode | EntityNode | IndexNode | TriggerNode | MessageNode;

export class DatabaseNode {
  readonly kind = 'database';
  constructor(readonly database: DatabaseDescriptor) {}
}

export class GroupNode {
  readonly kind = 'group';
  constructor(
    readonly database: DatabaseDescriptor,
    readonly label: string,
    readonly children: TreeNode[],
    readonly icon: string,
  ) {}
}

export class EntityNode {
  readonly kind = 'entity';
  constructor(
    readonly database: DatabaseDescriptor,
    readonly entity: EntitySummary,
  ) {}
}

export class IndexNode {
  readonly kind = 'index';
  constructor(
    readonly database: DatabaseDescriptor,
    readonly index: IndexInfo,
  ) {}
}

export class TriggerNode {
  readonly kind = 'trigger';
  constructor(
    readonly database: DatabaseDescriptor,
    readonly trigger: TriggerInfo,
  ) {}
}

export class MessageNode {
  readonly kind = 'message';
  constructor(
    readonly message: string,
    readonly icon = 'info',
  ) {}
}

/**
 * Native tree of databases and their entities. Layout follows each
 * database's data model; actions follow its capabilities.
 */
export class DatabaseTreeProvider implements vscode.TreeDataProvider<TreeNode> {
  private readonly changed = new vscode.EventEmitter<TreeNode | undefined>();
  readonly onDidChangeTreeData = this.changed.event;

  private databases: DatabaseDescriptor[] = [];
  private readonly overviews = new Map<string, Promise<SchemaOverview>>();
  private loadError?: string;
  private filterText = '';

  constructor(
    private readonly client: InspectorClient,
    private readonly manager: ConnectionManager,
  ) {}

  get current(): readonly DatabaseDescriptor[] {
    return this.databases;
  }

  /** Current table-name filter ('' when none). */
  get filter(): string {
    return this.filterText;
  }

  /** Shows only tables/collections/boxes (and indexes/triggers) whose name contains [text]. */
  setFilter(text: string): void {
    const next = text.trim();
    if (next === this.filterText) return;
    this.filterText = next;
    void vscode.commands.executeCommand('setContext', 'flutterDbInspector.treeFiltered', next !== '');
    this.changed.fire(undefined);
  }

  /** `[start, end]` of the filter match in [name], if any. */
  private match(name: string): [number, number] | undefined {
    if (!this.filterText) return undefined;
    const start = name.toLowerCase().indexOf(this.filterText.toLowerCase());
    return start < 0 ? undefined : [start, start + this.filterText.length];
  }

  private matches(name: string): boolean {
    return !this.filterText || this.match(name) !== undefined;
  }

  private highlighted(name: string): string | vscode.TreeItemLabel {
    const range = this.match(name);
    return range ? { label: name, highlights: [range] } : name;
  }

  /** Reloads databases and drops cached schemas. */
  async refresh(): Promise<void> {
    this.overviews.clear();
    this.loadError = undefined;
    if (!this.manager.isConnected) {
      this.databases = [];
    } else {
      try {
        this.databases = await this.client.listDatabases();
      } catch (error) {
        this.databases = [];
        this.loadError = error instanceof Error ? error.message : String(error);
      }
    }
    await vscode.commands.executeCommand(
      'setContext',
      'flutterDbInspector.noDatabases',
      this.manager.isConnected && !this.loadError && this.databases.length === 0,
    );
    this.changed.fire(undefined);
  }

  /** Cached `schema.list` of a database. */
  overview(database: DatabaseDescriptor): Promise<SchemaOverview> {
    let overview = this.overviews.get(database.id);
    if (!overview) {
      overview = this.client.schema(database.id);
      overview.catch(() => this.overviews.delete(database.id));
      this.overviews.set(database.id, overview);
    }
    return overview;
  }

  invalidate(databaseId: string): void {
    this.overviews.delete(databaseId);
    const node = this.databases.find((d) => d.id === databaseId);
    this.changed.fire(undefined);
    void node;
  }

  getTreeItem(node: TreeNode): vscode.TreeItem {
    switch (node.kind) {
      case 'database': {
        const db = node.database;
        const item = new vscode.TreeItem(
          db.name,
          this.databases.length === 1 || this.filterText
            ? vscode.TreeItemCollapsibleState.Expanded
            : vscode.TreeItemCollapsibleState.Collapsed,
        );
        // A different id while filtering expands every database, and the
        // user's own expand/collapse state comes back when the filter clears.
        item.id = this.filterText ? `db:${db.id}:filtered` : `db:${db.id}`;
        item.description = `${engineLabel(db.type)}${db.readOnly ? ' · read-only' : ''}`;
        item.iconPath = new vscode.ThemeIcon('database');
        item.contextValue = ['database', ...db.capabilities.filter((c) => c === 'sql' || c === 'export')].join(':');
        item.tooltip = new vscode.MarkdownString(
          [
            `**${db.name}** \`${db.id}\``,
            `Engine: ${engineLabel(db.type)} (${dataModelLabel(db.dataModel)})`,
            `Access: ${db.readOnly ? 'read-only' : 'read & write'}`,
            `Capabilities: ${db.capabilities.join(', ')}`,
          ].join('\n\n'),
        );
        return item;
      }
      case 'group': {
        const item = new vscode.TreeItem(node.label, vscode.TreeItemCollapsibleState.Expanded);
        item.id = `group:${node.database.id}:${node.label}${this.filterText ? ':filtered' : ''}`;
        item.description = String(node.children.length);
        item.iconPath = new vscode.ThemeIcon(node.icon);
        item.contextValue = 'group';
        return item;
      }
      case 'entity': {
        const { database: db, entity } = node;
        const item = new vscode.TreeItem(this.highlighted(entity.name), vscode.TreeItemCollapsibleState.None);
        item.id = `entity:${db.id}:${entity.kind}:${entity.name}`;
        item.description = entity.rowCount === undefined ? undefined : formatCount(entity.rowCount);
        item.iconPath = new vscode.ThemeIcon(entityIcon(entity.kind));
        const writable = !db.readOnly && !entity.readOnly;
        const flags = ['entity'];
        if (db.capabilities.includes('export')) flags.push('export');
        if (writable && db.capabilities.includes('clear')) flags.push('clear');
        item.contextValue = flags.join(':');
        item.tooltip = `${entity.kind} ${entity.name}${
          entity.rowCount === undefined ? '' : ` — ${formatCount(entity.rowCount)} ${recordNoun(entity.kind, true)}`
        }${entity.readOnly ? ' (read-only)' : ''}`;
        item.command = {
          command: 'flutterDbInspector.openTable',
          title: 'Open Data',
          arguments: [node],
        };
        return item;
      }
      case 'index': {
        const { index } = node;
        const item = new vscode.TreeItem(this.highlighted(index.name), vscode.TreeItemCollapsibleState.None);
        item.description = `${index.table}(${index.columns.join(', ')})${index.unique ? ' unique' : ''}`;
        item.iconPath = new vscode.ThemeIcon('list-ordered');
        item.contextValue = 'index';
        item.tooltip = index.sql ?? `${index.unique ? 'UNIQUE ' : ''}INDEX on ${index.table}`;
        return item;
      }
      case 'trigger': {
        const item = new vscode.TreeItem(this.highlighted(node.trigger.name), vscode.TreeItemCollapsibleState.None);
        item.description = node.trigger.table;
        item.iconPath = new vscode.ThemeIcon('zap');
        item.contextValue = 'trigger';
        item.tooltip = node.trigger.sql;
        return item;
      }
      case 'message': {
        const item = new vscode.TreeItem(node.message, vscode.TreeItemCollapsibleState.None);
        item.iconPath = new vscode.ThemeIcon(node.icon);
        return item;
      }
    }
  }

  async getChildren(node?: TreeNode): Promise<TreeNode[]> {
    if (!node) {
      if (this.loadError) return [new MessageNode(this.loadError, 'error')];
      return this.databases.map((d) => new DatabaseNode(d));
    }
    if (node.kind === 'group') return node.children;
    if (node.kind !== 'database') return [];

    const db = node.database;
    let overview: SchemaOverview;
    try {
      overview = await this.overview(db);
    } catch (error) {
      return [new MessageNode(error instanceof Error ? error.message : String(error), 'error')];
    }
    if (overview.entities.length === 0) return [new MessageNode('Empty', 'circle-slash')];

    const entitiesShown = overview.entities.filter((e) => this.matches(e.name));
    const byKind = new Map<string, EntitySummary[]>();
    for (const e of entitiesShown) {
      const list = byKind.get(e.kind) ?? [];
      list.push(e);
      byKind.set(e.kind, list);
    }
    // Primary data first (tables / collections / boxes), derived views after.
    const order = ['table', 'collection', 'box', 'store', 'view'];
    const rank = (kind: string) => (order.includes(kind) ? order.indexOf(kind) : order.length);
    const groups: TreeNode[] = [];
    for (const [kind, entities] of [...byKind].sort(([a], [b]) => rank(a) - rank(b))) {
      groups.push(
        new GroupNode(
          db,
          entityGroupLabel(kind),
          entities.map((e) => new EntityNode(db, e)),
          entityIcon(kind),
        ),
      );
    }
    if (overview.indexes.length > 0 && db.capabilities.includes('indexes')) {
      const visible = overview.indexes.filter((i) => i.origin !== 'pk' && this.matches(i.name));
      if (visible.length > 0) {
        groups.push(new GroupNode(db, 'Indexes', visible.map((i) => new IndexNode(db, i)), 'list-ordered'));
      }
    }
    const triggers = overview.triggers.filter((t) => this.matches(t.name));
    if (triggers.length > 0) {
      groups.push(new GroupNode(db, 'Triggers', triggers.map((t) => new TriggerNode(db, t)), 'zap'));
    }
    if (groups.length === 0 && this.filterText) {
      return [new MessageNode(`No names match "${this.filterText}"`, 'search')];
    }
    return groups;
  }
}

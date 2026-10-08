import type { AppInitMessage, InitMessage, OpenTarget, Theme, ViewKind } from '@messages';
import { dataModelLabel, engineLabel, entityGroupLabel, entityIcon, recordNoun } from '@labels';
import type { DatabaseDescriptor, EntityKind, EntitySummary, InspectorStatus, SchemaOverview } from '@protocol/types';
import { formatCount, relativeTime } from '@protocol/values';
import type { HistoryEntry, SavedQuery } from '@services/queryStore';
import { exportTable, client, queries, settings, viewHost, type ShellCallbacks } from './appHost';
import { confirmDialog } from './dialog';
import { announce, append, button, clear, h, icon, showMenu, type MenuItem } from './dom';
import { request } from './host';
import { SqlView } from './sqlView';
import { StatsView } from './statsView';
import { TableView } from './tableView';

/** Order of entity groups in the tree. */
const KIND_ORDER = ['table', 'view', 'collection', 'box', 'store'];

type Overview = SchemaOverview | { error: string } | 'loading';

type TreeNode =
  | { type: 'db'; key: string; db: DatabaseDescriptor }
  | { type: 'group'; key: string; db: DatabaseDescriptor; kind: EntityKind; count: number }
  | { type: 'entity'; key: string; db: DatabaseDescriptor; entity: EntitySummary }
  | { type: 'meta'; key: string; db: DatabaseDescriptor; what: 'indexes' | 'triggers'; count: number }
  | { type: 'index'; key: string; db: DatabaseDescriptor; name: string; table: string; sql?: string }
  | { type: 'trigger'; key: string; db: DatabaseDescriptor; name: string; table: string; sql?: string }
  | { type: 'message'; key: string; text: string; error?: boolean };

interface Tab {
  key: string;
  databaseId: string;
  view: TableView | SqlView | StatsView;
  title: string;
  icon: string;
  panel: HTMLElement;
  history?: HTMLElement;
}

/** The whole inspector in one page: database tree, tabs, history, footer. */
export class AppShell implements ShellCallbacks {
  private databases: DatabaseDescriptor[] = [];
  private readonly overviews = new Map<string, Overview>();
  private status?: InspectorStatus;
  private listError?: string;
  private loading = false;
  private connection: { state: string; message?: string } = { state: 'connecting' };
  private filter = '';
  /** Nodes whose expansion differs from their default. */
  private readonly toggled = new Set<string>();
  private selectedKey?: string;
  private loadSeq = 0;

  private readonly tabs = new Map<string, Tab>();
  private activeKey?: string;
  private historyOpen = true;

  private readonly root = h('div', { class: 'app-shell' });
  private readonly sidebar = h('aside', { class: 'app-sidebar', 'aria-label': 'Databases' });
  private readonly tree = h('div', { class: 'tree', role: 'tree', tabindex: 0, 'aria-label': 'Databases and tables' });
  private readonly filterInput = h('input', {
    class: 'input',
    type: 'search',
    placeholder: 'Filter tables…',
    'aria-label': 'Filter tables by name',
  });
  private readonly footer = h('div', { class: 'app-footer', role: 'status' });
  private readonly tabStrip = h('div', { class: 'app-tabs', role: 'tablist', 'aria-label': 'Open views' });
  private readonly tabActions = h('div', { class: 'app-tab-actions' });
  private readonly panels = h('div', { class: 'app-panels' });
  private readonly toasts = h('div', { class: 'toasts', 'aria-live': 'polite' });

  constructor(private readonly init: AppInitMessage) {
    settings.confirmCellEdits = init.confirmCellEdits ?? false;
    settings.historyLimit = init.historyLimit ?? 100;
    if (init.theme) this.setTheme(init.theme);
    queries.onDidChange(() => this.renderHistory());
  }

  mount(app: HTMLElement): void {
    const resizer = h('div', { class: 'app-resizer', role: 'separator', title: 'Drag to resize · double-click to reset' });
    resizer.setAttribute('aria-orientation', 'vertical');
    this.sidebar.append(
      h(
        'div',
        { class: 'app-sidebar-header' },
        h('span', { class: 'app-sidebar-title' }, 'DATABASES'),
        button('Reload', () => void this.loadAll(), { icon: 'refresh', iconOnly: true, title: 'Reload databases' }),
      ),
      h('div', { class: 'app-filter' }, this.filterInput),
      this.tree,
      this.footer,
    );
    this.root.append(
      this.sidebar,
      resizer,
      h('main', { class: 'app-main' }, h('div', { class: 'app-tabbar' }, this.tabStrip, this.tabActions), this.panels),
      this.toasts,
    );
    app.appendChild(this.root);
    this.setupResizer(resizer);
    this.filterInput.addEventListener('input', () => {
      this.filter = this.filterInput.value.trim().toLowerCase();
      this.renderTree();
    });
    this.filterInput.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        this.tree.focus();
      }
    });
    this.tree.addEventListener('keydown', (e) => this.onTreeKey(e));
    this.renderTree();
    this.renderTabs();
    this.renderFooter();
    void this.loadAll();
  }

  // ---------------------------------------------------------------------------
  // Host events

  setTheme(theme: Theme): void {
    document.documentElement.dataset.theme = theme;
  }

  setConnection(state: string, message?: string): void {
    const was = this.connection.state;
    this.connection = { state, message };
    for (const tab of this.tabs.values()) {
      if (tab.view instanceof TableView) tab.view.setConnection(state, message);
      else if (tab.view instanceof SqlView) tab.view.setConnection(state);
    }
    this.renderFooter();
    if (state === 'connected' && was !== 'connected') void this.reloadEverything();
    if (state !== 'connected') this.renderTree();
  }

  onEvent(name: string): void {
    if (name.endsWith('databasesChanged')) void this.loadAll();
  }

  async reloadEverything(): Promise<void> {
    await this.loadAll();
    for (const tab of this.tabs.values()) {
      if (tab.view instanceof TableView || tab.view instanceof StatsView) tab.view.refresh();
    }
  }

  // ---------------------------------------------------------------------------
  // ShellCallbacks

  open(target: OpenTarget): void {
    const db = this.databases.find((d) => d.id === target.databaseId);
    if (!db) {
      this.notify(`Database "${target.databaseId}" is not available.`, 'error');
      return;
    }
    const key = tabKey(target.view, db.id, target.table);
    const existing = this.tabs.get(key);
    if (existing) {
      if (existing.view instanceof TableView && target.tab) existing.view.showTab(target.tab);
      if (existing.view instanceof SqlView && target.sql !== undefined) {
        if (target.suggest) existing.view.suggestSql(target.sql);
        else existing.view.setSql(target.sql, false);
      }
      this.activate(key);
      return;
    }
    const entity = target.table ? this.entity(db.id, target.table) : undefined;
    const kind = entity?.kind ?? (target.table ? 'table' : undefined);
    const init: InitMessage = {
      type: 'init',
      view: target.view,
      database: db,
      table: target.table,
      entityKind: kind,
      tab: target.tab ?? 'data',
      pageSize: this.init.pageSize,
      limits: this.status?.limits,
      sql: target.sql,
    };
    const host = viewHost(key, () => this.databases.find((d) => d.id === db.id) ?? db, target.table, kind, this);
    const panel = h('div', { class: 'app-panel', role: 'tabpanel' });
    const content = h('div', { class: 'app-panel-content' });
    panel.appendChild(content);
    let view: Tab['view'];
    let title: string;
    let tabIcon: string;
    switch (target.view) {
      case 'table':
        view = new TableView(init, host);
        title = target.table!;
        tabIcon = entityIcon(kind ?? 'table');
        break;
      case 'sql':
        view = new SqlView(init, host);
        title = `SQL · ${db.name}`;
        tabIcon = 'terminal';
        break;
      case 'stats':
        view = new StatsView(init, host);
        title = `Statistics · ${db.name}`;
        tabIcon = 'graph';
        break;
    }
    const tab: Tab = { key, databaseId: db.id, view, title, icon: tabIcon, panel };
    if (view instanceof SqlView) {
      tab.history = h('aside', { class: 'history-panel', 'aria-label': 'Query history' });
      panel.appendChild(tab.history);
    }
    this.tabs.set(key, tab);
    this.panels.appendChild(panel);
    view.mount(content);
    if (view instanceof TableView) view.setConnection(this.connection.state, this.connection.message);
    else if (view instanceof SqlView) view.setConnection(this.connection.state);
    this.activate(key);
    if (target.sql && view instanceof SqlView) {
      if (target.suggest) view.suggestSql(target.sql);
      else view.setSql(target.sql, false);
    }
    this.renderHistory();
  }

  dataChanged(databaseId: string): void {
    void this.loadOverview(databaseId);
    for (const tab of this.tabs.values()) {
      if (tab.databaseId === databaseId && tab.view instanceof StatsView) tab.view.refresh();
    }
  }

  notify(message: string, level: 'info' | 'warning' | 'error' = 'info'): void {
    announce(message);
    const toast = h(
      'div',
      { class: `toast ${level}`, role: level === 'error' ? 'alert' : 'status' },
      icon(level === 'error' ? 'error' : level === 'warning' ? 'warning' : 'info'),
      h('span', {}, message),
    );
    this.toasts.appendChild(toast);
    setTimeout(() => toast.remove(), level === 'info' ? 3500 : 7000);
  }

  // ---------------------------------------------------------------------------
  // Loading

  private async loadAll(): Promise<void> {
    const seq = ++this.loadSeq;
    this.loading = true;
    this.renderTree();
    try {
      const [status, databases] = await Promise.all([client.status().catch(() => undefined), client.listDatabases()]);
      if (seq !== this.loadSeq) return;
      this.status = status ?? this.status;
      this.databases = databases;
      this.listError = undefined;
      for (const id of [...this.overviews.keys()]) if (!databases.some((d) => d.id === id)) this.overviews.delete(id);
      // Tabs of databases that are gone cannot work any more.
      for (const tab of [...this.tabs.values()]) if (!databases.some((d) => d.id === tab.databaseId)) this.closeTab(tab.key);
    } catch (error) {
      if (seq !== this.loadSeq) return;
      this.listError = error instanceof Error ? error.message : String(error);
    } finally {
      if (seq === this.loadSeq) this.loading = false;
    }
    this.renderTree();
    this.renderFooter();
    await Promise.all(this.databases.map((d) => this.loadOverview(d.id)));
  }

  private async loadOverview(databaseId: string): Promise<void> {
    if (!this.overviews.has(databaseId)) this.overviews.set(databaseId, 'loading');
    this.renderTree();
    try {
      this.overviews.set(databaseId, await client.schema(databaseId));
    } catch (error) {
      this.overviews.set(databaseId, { error: error instanceof Error ? error.message : String(error) });
    }
    this.renderTree();
  }

  private entity(databaseId: string, name: string): EntitySummary | undefined {
    const o = this.overviews.get(databaseId);
    return o && typeof o === 'object' && 'entities' in o ? o.entities.find((e) => e.name === name) : undefined;
  }

  // ---------------------------------------------------------------------------
  // Tree

  private isExpanded(key: string): boolean {
    // Databases and groups start expanded; index / trigger lists collapsed.
    const byDefault = !key.startsWith('meta:');
    return this.filter ? true : byDefault !== this.toggled.has(key);
  }

  private toggle(key: string, expanded?: boolean): void {
    if (expanded !== undefined && this.isExpanded(key) === expanded) return;
    if (this.toggled.has(key)) this.toggled.delete(key);
    else this.toggled.add(key);
    this.renderTree();
  }

  /** Visible nodes in display order, with their depth. */
  private visibleNodes(): { node: TreeNode; level: number; hasChildren: boolean }[] {
    const out: { node: TreeNode; level: number; hasChildren: boolean }[] = [];
    if (this.connection.state !== 'connected' && !this.databases.length) {
      const text =
        this.connection.state === 'error' || this.connection.state === 'disconnected'
          ? (this.connection.message ?? 'Not connected to a running app.')
          : 'Waiting for a running app…';
      out.push({ node: { type: 'message', key: 'm:conn', text, error: this.connection.state === 'error' }, level: 1, hasChildren: false });
      return out;
    }
    if (this.listError) {
      out.push({ node: { type: 'message', key: 'm:err', text: this.listError, error: true }, level: 1, hasChildren: false });
      return out;
    }
    if (!this.databases.length) {
      const text = this.loading ? 'Loading databases…' : 'No databases registered. Call DbInspector.registerDatabase() in the app.';
      out.push({ node: { type: 'message', key: 'm:empty', text }, level: 1, hasChildren: false });
      return out;
    }
    const match = (name: string) => !this.filter || name.toLowerCase().includes(this.filter);
    let anyMatch = false;
    for (const db of this.databases) {
      const dbKey = `db:${db.id}`;
      const overview = this.overviews.get(db.id);
      const children: { node: TreeNode; level: number; hasChildren: boolean }[] = [];
      if (overview === undefined || overview === 'loading') {
        children.push({ node: { type: 'message', key: `m:${db.id}:loading`, text: 'Loading…' }, level: 2, hasChildren: false });
      } else if ('error' in overview) {
        children.push({ node: { type: 'message', key: `m:${db.id}:error`, text: overview.error, error: true }, level: 2, hasChildren: false });
      } else {
        const kinds = [...new Set(overview.entities.map((e) => e.kind))].sort(
          (a, b) => rank(a) - rank(b) || a.localeCompare(b),
        );
        for (const kind of kinds) {
          const entities = overview.entities.filter((e) => e.kind === kind && match(e.name));
          if (!entities.length) continue;
          const groupKey = `group:${db.id}:${kind}`;
          children.push({ node: { type: 'group', key: groupKey, db, kind, count: entities.length }, level: 2, hasChildren: true });
          if (this.isExpanded(groupKey)) {
            for (const entity of entities) {
              children.push({ node: { type: 'entity', key: `entity:${db.id}:${entity.name}`, db, entity }, level: 3, hasChildren: false });
            }
          }
        }
        const indexes = db.capabilities.includes('indexes')
          ? overview.indexes.filter((i) => i.origin !== 'pk' && (match(i.name) || match(i.table)))
          : [];
        const triggers = overview.triggers.filter((t) => match(t.name) || match(t.table));
        for (const [what, items] of [['indexes', indexes], ['triggers', triggers]] as const) {
          if (!items.length) continue;
          const metaKey = `meta:${db.id}:${what}`;
          children.push({ node: { type: 'meta', key: metaKey, db, what, count: items.length }, level: 2, hasChildren: true });
          if (this.isExpanded(metaKey)) {
            for (const item of items) {
              const node: TreeNode =
                what === 'indexes'
                  ? { type: 'index', key: `index:${db.id}:${item.name}`, db, name: item.name, table: item.table, sql: item.sql }
                  : { type: 'trigger', key: `trigger:${db.id}:${item.name}`, db, name: item.name, table: item.table, sql: item.sql };
              children.push({ node, level: 3, hasChildren: false });
            }
          }
        }
        if (!overview.entities.length) {
          children.push({ node: { type: 'message', key: `m:${db.id}:none`, text: `No ${entityGroupLabel(defaultKind(db)).toLowerCase()}` }, level: 2, hasChildren: false });
        }
      }
      const dbMatches = match(db.name);
      const childMatches = children.some((c) => c.node.type === 'entity' || c.node.type === 'index' || c.node.type === 'trigger');
      if (this.filter && !dbMatches && !childMatches) continue;
      anyMatch = true;
      out.push({ node: { type: 'db', key: dbKey, db }, level: 1, hasChildren: true });
      if (this.isExpanded(dbKey)) out.push(...children);
    }
    if (this.filter && !anyMatch) {
      out.push({ node: { type: 'message', key: 'm:nomatch', text: 'No names match the filter.' }, level: 1, hasChildren: false });
    }
    return out;
  }

  private renderTree(): void {
    const nodes = this.visibleNodes();
    if (!nodes.some((n) => n.node.key === this.selectedKey)) this.selectedKey = nodes.find((n) => n.node.type !== 'message')?.node.key;
    clear(this.tree);
    for (const { node, level, hasChildren } of nodes) {
      const selected = node.key === this.selectedKey;
      const row = h('div', {
        class: `tree-item${selected ? ' selected' : ''}${node.type === 'message' ? ' message' : ''}${node.type === 'message' && node.error ? ' error-text' : ''}`,
        role: 'treeitem',
        dataset: { key: node.key },
      });
      row.setAttribute('aria-level', String(level));
      row.setAttribute('aria-selected', String(selected));
      if (hasChildren) row.setAttribute('aria-expanded', String(this.isExpanded(node.key)));
      row.style.paddingLeft = `${4 + (level - 1) * 14}px`;
      append(
        row,
        hasChildren
          ? h('span', {
              class: `codicon codicon-chevron-${this.isExpanded(node.key) ? 'down' : 'right'} twisty`,
              on: {
                click: (e) => {
                  e.stopPropagation();
                  this.toggle(node.key);
                },
              },
            })
          : h('span', { class: 'twisty' }),
        ...this.nodeContent(node),
      );
      if (node.type !== 'message') {
        row.addEventListener('click', () => this.select(node.key));
        row.addEventListener('dblclick', () => this.activateNode(node));
        row.addEventListener('contextmenu', (e) => {
          e.preventDefault();
          this.select(node.key);
          this.nodeMenu(node, e.clientX, e.clientY);
        });
        const title = this.nodeTooltip(node);
        if (title) row.title = title;
      }
      this.tree.appendChild(row);
    }
    if (this.selectedKey) this.tree.setAttribute('aria-activedescendant', this.selectedKey);
  }

  private nodeContent(node: TreeNode): (Node | string | null)[] {
    switch (node.type) {
      case 'db':
        return [
          icon('database'),
          h('span', { class: 'tree-label' }, node.db.name),
          h('span', { class: 'tree-desc' }, engineLabel(node.db.type)),
          node.db.readOnly ? h('span', { class: 'badge warn' }, 'read-only') : null,
        ];
      case 'group':
        return [h('span', { class: 'tree-label' }, entityGroupLabel(node.kind)), h('span', { class: 'tree-desc' }, String(node.count))];
      case 'entity':
        return [
          icon(entityIcon(node.entity.kind)),
          h('span', { class: 'tree-label' }, node.entity.name),
          node.entity.rowCount !== undefined ? h('span', { class: 'tree-desc' }, formatCount(node.entity.rowCount)) : null,
          // A read-only database already carries the badge.
          node.entity.readOnly && node.entity.kind !== 'view' && !node.db.readOnly ? h('span', { class: 'badge warn' }, 'read-only') : null,
        ];
      case 'meta':
        return [h('span', { class: 'tree-label' }, node.what === 'indexes' ? 'Indexes' : 'Triggers'), h('span', { class: 'tree-desc' }, String(node.count))];
      case 'index':
        return [icon('list-ordered'), h('span', { class: 'tree-label' }, node.name), h('span', { class: 'tree-desc' }, node.table)];
      case 'trigger':
        return [icon('zap'), h('span', { class: 'tree-label' }, node.name), h('span', { class: 'tree-desc' }, node.table)];
      case 'message':
        return [h('span', { class: 'tree-label' }, node.text)];
    }
  }

  private nodeTooltip(node: TreeNode): string | undefined {
    switch (node.type) {
      case 'db':
        return [
          `${node.db.name} (${node.db.id})`,
          `Engine: ${engineLabel(node.db.type)}`,
          `Data model: ${dataModelLabel(node.db.dataModel)}`,
          `Access: ${node.db.readOnly ? 'read-only' : 'read / write'}`,
          `Capabilities: ${node.db.capabilities.join(', ')}`,
        ].join('\n');
      case 'entity':
        return `${node.entity.name} — ${node.entity.kind}${node.entity.rowCount !== undefined ? `, ${formatCount(node.entity.rowCount)} ${recordNoun(node.entity.kind, node.entity.rowCount !== 1)}` : ''}`;
      case 'index':
      case 'trigger':
        return node.sql ?? `${node.name} on ${node.table}`;
      default:
        return undefined;
    }
  }

  private select(key: string): void {
    this.selectedKey = key;
    for (const el of this.tree.querySelectorAll<HTMLElement>('.tree-item')) {
      const on = el.dataset.key === key;
      el.classList.toggle('selected', on);
      el.setAttribute('aria-selected', String(on));
      if (on) el.scrollIntoView({ block: 'nearest' });
    }
    this.tree.setAttribute('aria-activedescendant', key);
  }

  /** Enter / double-click. */
  private activateNode(node: TreeNode): void {
    switch (node.type) {
      case 'db':
      case 'group':
      case 'meta':
        this.toggle(node.key);
        break;
      case 'entity':
        this.open({ view: 'table', databaseId: node.db.id, table: node.entity.name, tab: 'data' });
        break;
      case 'index':
      case 'trigger':
        this.open({ view: 'table', databaseId: node.db.id, table: node.table, tab: 'schema' });
        break;
    }
  }

  private onTreeKey(e: KeyboardEvent): void {
    const nodes = this.visibleNodes().filter((n) => n.node.type !== 'message');
    if (!nodes.length) return;
    let index = nodes.findIndex((n) => n.node.key === this.selectedKey);
    if (index < 0) index = 0;
    const current = nodes[index]!;
    const move = (i: number) => this.select(nodes[Math.max(0, Math.min(nodes.length - 1, i))]!.node.key);
    switch (e.key) {
      case 'ArrowDown':
        move(index + 1);
        break;
      case 'ArrowUp':
        move(index - 1);
        break;
      case 'Home':
        move(0);
        break;
      case 'End':
        move(nodes.length - 1);
        break;
      case 'ArrowRight':
        if (current.hasChildren && !this.isExpanded(current.node.key)) this.toggle(current.node.key, true);
        else move(index + 1);
        break;
      case 'ArrowLeft':
        if (current.hasChildren && this.isExpanded(current.node.key)) this.toggle(current.node.key, false);
        else {
          for (let i = index - 1; i >= 0; i--) {
            if (nodes[i]!.level < current.level) {
              move(i);
              break;
            }
          }
        }
        break;
      case 'Enter':
      case ' ':
        this.activateNode(current.node);
        break;
      case 'ContextMenu': {
        const row = this.tree.querySelector<HTMLElement>(`[data-key="${CSS.escape(current.node.key)}"]`);
        const rect = row?.getBoundingClientRect();
        this.nodeMenu(current.node, rect ? rect.left + 24 : 24, rect ? rect.bottom : 24);
        break;
      }
      default:
        return;
    }
    e.preventDefault();
  }

  private nodeMenu(node: TreeNode, x: number, y: number): void {
    const copy = (text: string, label: string): MenuItem => ({
      label: label === 'name' ? 'Copy Name' : 'Copy SQL',
      icon: 'copy',
      run: () => void request({ op: 'copy', text, label }),
    });
    const items: (MenuItem | 'separator')[] = [];
    switch (node.type) {
      case 'db': {
        const db = node.db;
        if (db.capabilities.includes('sql')) items.push({ label: 'SQL Console', icon: 'terminal', run: () => this.open({ view: 'sql', databaseId: db.id }) });
        items.push(
          { label: 'Statistics', icon: 'graph', run: () => this.open({ view: 'stats', databaseId: db.id }) },
          { label: 'Refresh', icon: 'refresh', run: () => void this.loadOverview(db.id) },
          'separator',
          copy(db.name, 'name'),
        );
        break;
      }
      case 'entity': {
        const { db, entity } = node;
        const writable = !db.readOnly && !entity.readOnly && entity.kind !== 'view' && this.status?.mode !== 'readOnly';
        items.push(
          { label: 'Open Data', icon: 'table', run: () => this.open({ view: 'table', databaseId: db.id, table: entity.name, tab: 'data' }) },
          {
            label: db.dataModel === 'relational' ? 'Open Schema' : 'Open Structure',
            icon: 'symbol-structure',
            run: () => this.open({ view: 'table', databaseId: db.id, table: entity.name, tab: 'schema' }),
          },
        );
        if (db.capabilities.includes('export')) {
          items.push({ label: 'Export…', icon: 'export', run: () => void exportTable(db, entity.name, entity.kind, this).catch((e) => this.fail(e)) });
        }
        if (writable && db.capabilities.includes('clear')) {
          items.push({
            label: `Delete All ${capitalize(recordNoun(entity.kind, true))}…`,
            icon: 'trash',
            danger: true,
            run: () => void this.clearEntity(db, entity),
          });
        }
        items.push('separator', copy(entity.name, 'name'));
        break;
      }
      case 'index':
      case 'trigger':
        items.push(
          { label: 'Open Table Schema', icon: 'symbol-structure', run: () => this.open({ view: 'table', databaseId: node.db.id, table: node.table, tab: 'schema' }) },
          'separator',
          copy(node.name, 'name'),
        );
        if (node.sql) items.push(copy(node.sql, 'SQL'));
        break;
      default:
        return;
    }
    showMenu(x, y, items);
  }

  /** Tree "Delete All…": same flow as the table view's toolbar button. */
  private async clearEntity(db: DatabaseDescriptor, entity: EntitySummary): Promise<void> {
    const host = viewHost(`clear:${db.id}`, () => db, entity.name, entity.kind, this);
    try {
      await host.request({ op: 'clear' });
      for (const tab of this.tabs.values()) {
        if (tab.key === tabKey('table', db.id, entity.name) && tab.view instanceof TableView) tab.view.refresh();
      }
    } catch (error) {
      this.fail(error);
    }
  }

  private fail(error: unknown): void {
    this.notify(error instanceof Error ? error.message : String(error), 'error');
  }

  // ---------------------------------------------------------------------------
  // Tabs

  private activate(key: string): void {
    this.activeKey = key;
    for (const tab of this.tabs.values()) tab.panel.hidden = tab.key !== key;
    this.renderTabs();
    this.renderHistory();
    const tab = this.tabs.get(key);
    if (tab) {
      const entityKey = tab.view instanceof TableView ? `entity:${tab.databaseId}:${key.split(':').slice(2).join(':')}` : `db:${tab.databaseId}`;
      if (this.tree.querySelector(`[data-key="${CSS.escape(entityKey)}"]`)) this.select(entityKey);
    }
  }

  private closeTab(key: string): void {
    const tab = this.tabs.get(key);
    if (!tab) return;
    const keys = [...this.tabs.keys()];
    const index = keys.indexOf(key);
    tab.panel.remove();
    this.tabs.delete(key);
    if (this.activeKey === key) {
      const next = keys[index + 1] ?? keys[index - 1];
      this.activeKey = undefined;
      if (next && next !== key) this.activate(next);
    }
    this.renderTabs();
  }

  private renderTabs(): void {
    clear(this.tabStrip);
    clear(this.tabActions);
    if (!this.tabs.size) {
      this.panels.querySelector('.app-empty')?.remove();
      this.panels.appendChild(
        h(
          'div',
          { class: 'app-empty' },
          icon('database'),
          h('p', {}, 'Double-click a table, collection or box to open it.'),
          h('p', { class: 'muted' }, 'Right-click a database for its SQL console and statistics.'),
        ),
      );
      return;
    }
    this.panels.querySelector('.app-empty')?.remove();
    for (const tab of this.tabs.values()) {
      const selected = tab.key === this.activeKey;
      const db = this.databases.find((d) => d.id === tab.databaseId);
      const el = h(
        'div',
        {
          class: `app-tab${selected ? ' selected' : ''}`,
          role: 'tab',
          tabindex: selected ? 0 : -1,
          title: `${tab.title} — ${db?.name ?? tab.databaseId}`,
          'aria-selected': String(selected),
          on: {
            click: () => this.activate(tab.key),
            auxclick: (e) => {
              if (e.button === 1) this.closeTab(tab.key);
            },
            keydown: (e) => {
              const keys = [...this.tabs.keys()];
              const i = keys.indexOf(tab.key);
              if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
                const next = keys[(i + (e.key === 'ArrowRight' ? 1 : -1) + keys.length) % keys.length]!;
                this.activate(next);
                this.tabStrip.querySelector<HTMLElement>('.app-tab.selected')?.focus();
                e.preventDefault();
              } else if (e.key === 'Delete') {
                this.closeTab(tab.key);
              }
            },
          },
        },
        icon(tab.icon),
        h('span', { class: 'app-tab-label' }, tab.title),
        h(
          'button',
          {
            class: 'app-tab-close',
            type: 'button',
            title: 'Close',
            'aria-label': `Close ${tab.title}`,
            tabindex: -1,
            on: {
              click: (e) => {
                e.stopPropagation();
                this.closeTab(tab.key);
              },
            },
          },
          icon('close'),
        ),
      );
      this.tabStrip.appendChild(el);
    }
    const active = this.activeKey ? this.tabs.get(this.activeKey) : undefined;
    if (active?.history) {
      const toggle = button('History', () => {
        this.historyOpen = !this.historyOpen;
        this.renderTabs();
        this.renderHistory();
      }, { icon: 'history', title: this.historyOpen ? 'Hide query history' : 'Show query history' });
      toggle.classList.toggle('on', this.historyOpen);
      toggle.setAttribute('aria-pressed', String(this.historyOpen));
      this.tabActions.appendChild(toggle);
    }
    if (this.tabs.size > 1) {
      this.tabActions.appendChild(
        button('Close All', () => {
          for (const key of [...this.tabs.keys()]) this.closeTab(key);
        }, { icon: 'close-all', iconOnly: true, title: 'Close all tabs' }),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // SQL history + saved queries

  private renderHistory(): void {
    for (const tab of this.tabs.values()) {
      if (!tab.history || !(tab.view instanceof SqlView)) continue;
      const panel = tab.history;
      panel.hidden = !this.historyOpen;
      if (tab.key !== this.activeKey || !this.historyOpen) continue;
      const db = this.databases.find((d) => d.id === tab.databaseId);
      const view = tab.view;
      clear(panel);
      const saved = queries.saved.filter((q) => !q.databaseType || q.databaseType === db?.type);
      const history = queries.history.filter((e) => e.databaseId === tab.databaseId);
      panel.append(h('h3', {}, 'Saved queries'));
      if (!saved.length) panel.append(h('p', { class: 'muted' }, 'None yet — save one from the editor.'));
      for (const q of saved) panel.append(this.queryItem(q.name, q.sql, view, undefined, () => void this.deleteSaved(q)));
      panel.append(
        h(
          'div',
          { class: 'history-heading' },
          h('h3', {}, 'History'),
          history.length ? button('Clear', () => void this.clearHistory(tab.databaseId, history), { icon: 'clear-all', iconOnly: true, title: 'Clear history for this database' }) : null,
        ),
      );
      if (settings.historyLimit <= 0) panel.append(h('p', { class: 'muted' }, 'History is turned off.'));
      else if (!history.length) panel.append(h('p', { class: 'muted' }, 'Queries you run appear here.'));
      for (const e of history) panel.append(this.queryItem(undefined, e.sql, view, e));
    }
  }

  private queryItem(name: string | undefined, sql: string, view: SqlView, entry?: HistoryEntry, onDelete?: () => void): HTMLElement {
    const meta = entry
      ? `${relativeTime(entry.at)}${entry.rowCount !== undefined ? ` · ${formatCount(entry.rowCount)} rows` : ''}${entry.elapsedMs !== undefined ? ` · ${entry.elapsedMs} ms` : ''}`
      : undefined;
    return h(
      'div',
      {
        class: `history-item${entry && !entry.ok ? ' failed' : ''}`,
        tabindex: 0,
        title: `${sql}\n\nClick to load · double-click to run`,
        on: {
          click: () => view.setSql(sql, false),
          dblclick: () => view.setSql(sql, true),
          keydown: (e) => {
            if (e.key === 'Enter') view.setSql(sql, true);
          },
        },
      },
      h(
        'div',
        { class: 'history-line' },
        entry ? icon(entry.ok ? 'pass' : 'error') : icon('bookmark'),
        h('span', { class: 'history-sql' }, name ?? sql.replace(/\s+/g, ' ')),
        button('Run', () => view.setSql(sql, true), { icon: 'play', iconOnly: true, title: 'Run' }),
        onDelete ? button('Delete', onDelete, { icon: 'trash', iconOnly: true, title: 'Delete saved query' }) : null,
      ),
      meta ? h('div', { class: 'history-meta muted' }, meta) : name ? h('div', { class: 'history-meta muted mono' }, sql.replace(/\s+/g, ' ')) : null,
    );
  }

  private async deleteSaved(q: SavedQuery): Promise<void> {
    if (await confirmDialog({ title: `Delete saved query "${q.name}"?`, code: q.sql, okLabel: 'Delete', danger: true })) {
      await queries.deleteSaved(q.id);
    }
  }

  private async clearHistory(databaseId: string, entries: HistoryEntry[]): Promise<void> {
    const db = this.databases.find((d) => d.id === databaseId);
    if (!(await confirmDialog({ title: `Clear query history for "${db?.name ?? databaseId}"?`, okLabel: 'Clear', danger: true }))) return;
    for (const e of entries) await queries.deleteHistory(e.id);
  }

  // ---------------------------------------------------------------------------
  // Footer / layout

  private renderFooter(): void {
    clear(this.footer);
    const { state, message } = this.connection;
    const label =
      state === 'connected' ? 'Connected' : state === 'reconnecting' ? 'Reconnecting…' : state === 'connecting' ? 'Connecting…' : state === 'error' ? 'Error' : 'Disconnected';
    const extras: string[] = [];
    if (this.status?.mode === 'readOnly') extras.push('read-only mode');
    if (this.status?.mode === 'disabled') extras.push('inspector disabled');
    if (this.status?.packageVersion) extras.push(`v${this.status.packageVersion}`);
    append(
      this.footer,
      h('span', { class: `dot ${state}` }),
      h('span', {}, label),
      extras.length ? h('span', { class: 'muted' }, ` · ${extras.join(' · ')}`) : null,
    );
    this.footer.title = [
      message,
      this.status ? `Package ${this.status.packageVersion} · protocol ${this.status.protocolVersion} · ${this.status.mode}` : undefined,
      `Host: ${this.init.host}`,
    ]
      .filter(Boolean)
      .join('\n');
  }

  private setupResizer(resizer: HTMLElement): void {
    const key = 'flutter_db_inspector.sidebarWidth';
    try {
      const saved = Number(window.localStorage.getItem(key));
      if (saved >= 160) this.sidebar.style.width = `${saved}px`;
    } catch {
      // Storage blocked.
    }
    resizer.addEventListener('mousedown', (e) => {
      e.preventDefault();
      const startX = e.clientX;
      const start = this.sidebar.getBoundingClientRect().width;
      const move = (ev: MouseEvent) => {
        const width = Math.max(160, Math.min(window.innerWidth - 320, start + ev.clientX - startX));
        this.sidebar.style.width = `${width}px`;
      };
      const up = () => {
        window.removeEventListener('mousemove', move);
        window.removeEventListener('mouseup', up);
        try {
          window.localStorage.setItem(key, String(Math.round(this.sidebar.getBoundingClientRect().width)));
        } catch {
          // Storage blocked.
        }
      };
      window.addEventListener('mousemove', move);
      window.addEventListener('mouseup', up);
    });
    resizer.addEventListener('dblclick', () => {
      this.sidebar.style.width = '';
    });
  }
}

function tabKey(view: ViewKind, databaseId: string, table?: string): string {
  return view === 'table' ? `table:${databaseId}:${table}` : `${view}:${databaseId}`;
}

function rank(kind: string): number {
  const i = KIND_ORDER.indexOf(kind);
  return i < 0 ? KIND_ORDER.length : i;
}

function defaultKind(db: DatabaseDescriptor): EntityKind {
  return db.dataModel === 'relational' ? 'table' : db.dataModel === 'keyValue' ? 'box' : 'collection';
}

function capitalize(s: string): string {
  return s ? s[0]!.toUpperCase() + s.slice(1) : s;
}

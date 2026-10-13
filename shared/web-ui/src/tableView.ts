import type { FullValue, InitMessage, TableTab } from '@messages';
import {
  FILTER_OPERATORS,
  type Capability,
  type ColumnInfo,
  type FilterOperator,
  type MutationResult,
  type RowFilter,
  type RowsPage,
  type RowSort,
  type TableSchemaResult,
  type WireValue,
} from '@protocol/types';
import {
  csvField,
  formatCount,
  isInlineEditable,
  isMasked,
  isPartial,
  isTagged,
  parseInput,
  rowToObject,
  sqlIdentifier,
  stringifyPlain,
  toPlain,
} from '@protocol/values';
import { announce, button, clear, h, icon, isMod, modKey, showMenu, type MenuItem } from './dom';
import { DataGrid, type GridColumn } from './grid';
import { HostError, isCancelled, type ViewHost } from './host';
import { recordNoun } from '@labels';
import { showRowForm } from './rowForm';
import { ValuePanel } from './valuePanel';

interface PersistedState {
  tab: TableTab;
  widths: Record<string, number>;
  pageSize: number;
}

/** Data + Schema screen for one table / collection / box. */
export class TableView {
  private readonly db: InitMessage['database'];
  private readonly table: string;
  private readonly state: PersistedState;

  private schema?: TableSchemaResult;
  private page?: RowsPage;
  private pageIndex = 0;
  private search = '';
  private filters: RowFilter[] = [];
  private draftFilters: RowFilter[] = [];
  private sort: RowSort[] = [];
  private loadSeq = 0;
  private connected = true;

  private readonly root = h('div', { class: 'view' });
  private readonly tabs = h('div', { class: 'tabs', role: 'tablist' });
  private readonly dataPane = h('section', { class: 'pane', role: 'tabpanel' });
  private readonly schemaPane = h('section', { class: 'pane schema-pane', role: 'tabpanel' });
  private readonly banner = h('div', { class: 'banner', hidden: true, role: 'status' });
  private readonly filterBar = h('div', { class: 'filter-bar', hidden: true });
  private readonly status = h('span', { class: 'status-text', 'aria-live': 'polite' });
  private readonly pager = h('div', { class: 'pager' });
  private readonly searchInput = h('input', {
    class: 'input search',
    type: 'search',
    placeholder: 'Search',
    'aria-label': 'Search all columns',
  });
  private readonly grid: DataGrid;
  private readonly valuePanel = new ValuePanel(() => this.grid.focus());

  constructor(
    private readonly init: InitMessage,
    private readonly host: ViewHost,
  ) {
    this.db = init.database;
    this.table = init.table!;
    this.state = this.host.loadState<PersistedState>({ tab: init.tab ?? 'data', widths: {}, pageSize: init.pageSize });
    this.grid = new DataGrid(
      {
        onSort: this.can('sort') ? (c) => this.toggleSort(c) : undefined,
        canEdit: (r, c) => this.canEditCell(r, c),
        onCommitEdit: (r, c, text) => this.commitEdit(r, c, text),
        onOpenCell: (r, c) => this.openValue(r, c),
        onSelect: (r, c) => {
          if (this.valuePanel.isOpen) this.openValue(r, c);
        },
        onContextMenu: (r, c, x, y) => this.cellMenu(r, c, x, y),
        onDeleteRow: (r) => void this.deleteRow(r),
        onCopyCell: (r, c) => this.copyCell(r, c),
        onCopyRow: (r) => this.copyRowJson(r),
      },
      this.state.widths,
      (widths) => this.persist({ widths }),
      `${this.table} data`,
    );
  }

  private can(capability: Capability): boolean {
    return this.db.capabilities.includes(capability);
  }

  mount(app: HTMLElement): void {
    const kind = this.init.entityKind ?? 'table';
    this.root.append(
      h(
        'header',
        { class: 'view-header' },
        h('div', { class: 'title' }, icon(kind === 'view' ? 'eye' : kind === 'collection' ? 'symbol-class' : kind === 'box' ? 'package' : 'table'),
          h('h1', {}, this.table),
          h('span', { class: 'badge' }, kind),
          this.db.readOnly ? h('span', { class: 'badge warn', title: 'Writes are disabled' }, 'read-only') : null),
        this.tabs,
      ),
      this.banner,
      this.dataPane,
      this.schemaPane,
    );
    app.appendChild(this.root);
    this.renderTabs();
    this.buildDataPane();
    document.addEventListener('keydown', (e) => this.onGlobalKey(e));
    void this.reload(true);
  }

  // ---------------------------------------------------------------------------
  // Host events

  refresh(): void {
    void this.reload(true);
  }

  showTab(tab: TableTab): void {
    this.persist({ tab });
    this.renderTabs();
  }

  setConnection(state: string, message?: string): void {
    this.connected = state === 'connected';
    this.banner.hidden = this.connected;
    this.banner.className = `banner ${state === 'error' || state === 'disconnected' ? 'error' : 'info'}`;
    clear(this.banner);
    if (!this.connected) {
      this.banner.append(
        icon(state === 'reconnecting' || state === 'connecting' ? 'sync~spin' : 'debug-disconnect'),
        ` ${message ?? (state === 'disconnected' ? 'The app is not connected.' : state)}`,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Layout

  private persist(patch: Partial<PersistedState>): void {
    Object.assign(this.state, patch);
    this.host.saveState(this.state);
  }

  private renderTabs(): void {
    clear(this.tabs);
    const tabs: { id: TableTab; label: string; icon: string }[] = [
      { id: 'data', label: 'Data', icon: 'table' },
      { id: 'schema', label: this.db.dataModel === 'relational' ? 'Schema' : 'Structure', icon: 'symbol-structure' },
    ];
    for (const tab of tabs) {
      const selected = this.state.tab === tab.id;
      const el = h(
        'button',
        {
          class: `tab${selected ? ' selected' : ''}`,
          role: 'tab',
          type: 'button',
          'aria-selected': String(selected),
          tabindex: selected ? 0 : -1,
          on: { click: () => this.showTab(tab.id) },
        },
        icon(tab.icon),
        tab.label,
      );
      this.tabs.appendChild(el);
    }
    this.dataPane.hidden = this.state.tab !== 'data';
    this.schemaPane.hidden = this.state.tab !== 'schema';
    if (this.state.tab === 'schema') this.renderSchema();
  }

  private buildDataPane(): void {
    const writable = !this.db.readOnly && this.init.entityKind !== 'view';
    let searchTimer: number | undefined;
    this.searchInput.addEventListener('input', () => {
      window.clearTimeout(searchTimer);
      searchTimer = window.setTimeout(() => {
        this.search = this.searchInput.value.trim();
        this.pageIndex = 0;
        void this.reload();
      }, 300);
    });

    const toolbar = h(
      'div',
      { class: 'toolbar main-toolbar', role: 'toolbar', 'aria-label': 'Table actions' },
      this.can('search') ? h('div', { class: 'search-box' }, icon('search'), this.searchInput) : null,
      this.can('filter')
        ? button('Filter', () => this.toggleFilterBar(), { icon: 'filter', title: 'Filter rows' })
        : null,
      button('Refresh', () => void this.reload(true), { icon: 'refresh', iconOnly: true, title: `Refresh (${modKey}R)` }),
      // Only SQL engines (sqflite, Drift, ...) have a console to open.
      this.can('sql')
        ? button('Query', () => void this.openQuery(), { icon: 'terminal', iconOnly: true, title: `Open the SQL console to query ${this.table}` })
        : null,
      h('span', { class: 'toolbar-sep' }),
      writable && this.can('insert') ? button('Add', () => this.addRow(), { icon: 'add', title: 'Add a record' }) : null,
      this.can('export') ? button('Export', () => void this.host.request({ op: 'export' }), { icon: 'export', title: 'Export…' }) : null,
      writable && this.can('clear')
        ? button('Clear', () => void this.clearTable(), { icon: 'clear-all', iconOnly: true, title: 'Delete all records…' })
        : null,
      h('span', { class: 'spacer' }),
      this.pager,
    );

    const body = h('div', { class: 'data-body' }, this.grid.element, this.valuePanel.element);
    this.dataPane.append(toolbar, this.filterBar, body, h('footer', { class: 'statusbar' }, this.status));
  }

  // ---------------------------------------------------------------------------
  // Loading

  private columnInfo(name: string): ColumnInfo | undefined {
    return this.schema?.schema.columns.find((c) => c.name === name);
  }

  private async reload(withSchema = false): Promise<void> {
    const seq = ++this.loadSeq;
    this.status.textContent = 'Loading…';
    this.dataPane.classList.add('loading');
    try {
      if (withSchema || !this.schema) {
        this.schema = await this.host.request<TableSchemaResult>({ op: 'schema' });
        if (this.state.tab === 'schema') this.renderSchema();
      }
      const started = performance.now();
      const page = await this.host.request<RowsPage>({
        op: 'rows',
        params: {
          page: this.pageIndex,
          pageSize: this.state.pageSize,
          filters: this.filters,
          sort: this.sort,
          search: this.search || undefined,
        },
      });
      if (seq !== this.loadSeq) return;
      // Page fell off the end (rows were deleted): go back to the last page.
      if (page.rows.length === 0 && this.pageIndex > 0 && page.total !== undefined) {
        this.pageIndex = Math.max(0, Math.ceil(page.total / this.state.pageSize) - 1);
        void this.reload();
        return;
      }
      this.page = page;
      const sensitive = new Set(this.schema?.sensitiveColumns ?? []);
      const columns: GridColumn[] = page.columns.map((c) => ({
        name: c.name,
        valueType: c.valueType,
        declaredType: c.declaredType,
        primaryKey: (this.columnInfo(c.name)?.primaryKeyPosition ?? 0) > 0,
        masked: sensitive.has(c.name),
      }));
      this.grid.setData(columns, page.rows, this.sort, this.pageIndex * this.state.pageSize);
      this.renderPager();
      const elapsed = Math.round(performance.now() - started);
      const total = page.total;
      const first = page.rows.length ? this.pageIndex * this.state.pageSize + 1 : 0;
      const last = this.pageIndex * this.state.pageSize + page.rows.length;
      const noun = this.recordNoun(total !== 1);
      this.status.textContent =
        total === undefined
          ? `${formatCount(page.rows.length)} ${noun} · ${elapsed} ms`
          : `${formatCount(first)}–${formatCount(last)} of ${formatCount(total)} ${noun}${
              this.filters.length || this.search ? ' (filtered)' : ''
            } · ${elapsed} ms`;
    } catch (error) {
      if (seq !== this.loadSeq) return;
      this.status.textContent = '';
      this.showError(error);
    } finally {
      if (seq === this.loadSeq) this.dataPane.classList.remove('loading');
    }
  }

  private recordNoun(plural: boolean): string {
    const kind = this.init.entityKind;
    const noun = kind === 'collection' ? 'object' : kind === 'box' || kind === 'store' ? 'entry' : 'row';
    return plural ? (noun === 'entry' ? 'entries' : `${noun}s`) : noun;
  }

  private showError(error: unknown): void {
    const message = error instanceof Error ? error.message : String(error);
    const code = error instanceof HostError ? error.code : '';
    this.status.textContent = '';
    this.status.append(h('span', { class: 'error-text' }, icon('error'), ` ${code ? `${code}: ` : ''}${message}`));
    announce(message);
  }

  private renderPager(): void {
    clear(this.pager);
    const total = this.page?.total;
    const pages = total === undefined ? undefined : Math.max(1, Math.ceil(total / this.state.pageSize));
    const go = (index: number) => {
      this.pageIndex = index;
      void this.reload();
    };
    const max = this.init.limits?.maxPageSize ?? 100;
    const size = h('select', { class: 'input', 'aria-label': 'Page size', title: 'Page size' });
    for (const n of [25, 50, 100].filter((n) => n <= max)) {
      const opt = h('option', { value: String(n) }, String(n));
      opt.selected = n === this.state.pageSize;
      size.appendChild(opt);
    }
    size.addEventListener('change', () => {
      this.persist({ pageSize: Number(size.value) });
      this.pageIndex = 0;
      void this.reload();
    });
    const hasNext = pages === undefined ? (this.page?.rows.length ?? 0) === this.state.pageSize : this.pageIndex < pages - 1;
    this.pager.append(
      size,
      button('First page', () => go(0), { icon: 'chevron-left', iconOnly: true, disabled: this.pageIndex === 0, title: 'First page' }),
      button('Previous page', () => go(this.pageIndex - 1), { icon: 'arrow-left', iconOnly: true, disabled: this.pageIndex === 0, title: 'Previous page' }),
      h('span', { class: 'page-label' }, `${formatCount(this.pageIndex + 1)}${pages ? ` / ${formatCount(pages)}` : ''}`),
      button('Next page', () => go(this.pageIndex + 1), { icon: 'arrow-right', iconOnly: true, disabled: !hasNext, title: 'Next page' }),
      button('Last page', () => go((pages ?? 1) - 1), { icon: 'chevron-right', iconOnly: true, disabled: !pages || this.pageIndex >= pages - 1, title: 'Last page' }),
    );
  }

  // ---------------------------------------------------------------------------
  // Sort & filter

  private toggleSort(column: string): void {
    const current = this.sort.find((s) => s.column === column);
    // asc → desc → none
    this.sort = !current ? [{ column, direction: 'asc' }] : current.direction === 'asc' ? [{ column, direction: 'desc' }] : [];
    this.pageIndex = 0;
    void this.reload();
  }

  private toggleFilterBar(): void {
    this.filterBar.hidden = !this.filterBar.hidden;
    if (!this.filterBar.hidden) {
      this.draftFilters = this.filters.length ? this.filters.map((f) => ({ ...f })) : [this.newFilter()];
      this.renderFilterBar();
    }
  }

  private newFilter(): RowFilter {
    const first = this.page?.columns.find((c) => !(this.schema?.sensitiveColumns ?? []).includes(c.name));
    return { column: first?.name ?? '', operator: 'contains', value: '' };
  }

  private renderFilterBar(): void {
    clear(this.filterBar);
    const sensitive = new Set(this.schema?.sensitiveColumns ?? []);
    const columns = (this.page?.columns ?? []).filter((c) => !sensitive.has(c.name));
    this.draftFilters.forEach((filter, index) => {
      const column = h('select', { class: 'input', 'aria-label': 'Column' });
      for (const c of columns) {
        const opt = h('option', { value: c.name }, c.name);
        opt.selected = c.name === filter.column;
        column.appendChild(opt);
      }
      column.addEventListener('change', () => (filter.column = column.value));
      const operator = h('select', { class: 'input', 'aria-label': 'Operator' });
      for (const op of FILTER_OPERATORS) {
        const opt = h('option', { value: op.id }, op.label);
        opt.selected = op.id === filter.operator;
        operator.appendChild(opt);
      }
      const value = h('input', { class: 'input', type: 'text', placeholder: 'value', 'aria-label': 'Value' });
      value.value = typeof filter.value === 'string' ? filter.value : filter.value === undefined ? '' : JSON.stringify(filter.value);
      const syncUnary = () => {
        value.hidden = FILTER_OPERATORS.find((o) => o.id === filter.operator)?.unary ?? false;
      };
      operator.addEventListener('change', () => {
        filter.operator = operator.value as FilterOperator;
        syncUnary();
      });
      value.addEventListener('input', () => (filter.value = value.value));
      value.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') this.applyFilters();
      });
      syncUnary();
      this.filterBar.appendChild(
        h(
          'div',
          { class: 'filter-row' },
          h('span', { class: 'muted filter-join' }, index === 0 ? 'Where' : 'and'),
          column,
          operator,
          value,
          button('Remove condition', () => {
            this.draftFilters.splice(index, 1);
            this.renderFilterBar();
          }, { icon: 'close', iconOnly: true }),
        ),
      );
    });
    this.filterBar.appendChild(
      h(
        'div',
        { class: 'toolbar' },
        button('Add condition', () => {
          this.draftFilters.push(this.newFilter());
          this.renderFilterBar();
        }, { icon: 'add' }),
        button('Apply', () => this.applyFilters(), { icon: 'check', primary: true }),
        button('Clear filters', () => {
          this.draftFilters = [];
          this.applyFilters();
          this.filterBar.hidden = true;
        }, { icon: 'clear-all' }),
      ),
    );
  }

  private applyFilters(): void {
    this.filters = this.draftFilters
      .filter((f) => f.column)
      .map((f) => {
        const unary = FILTER_OPERATORS.find((o) => o.id === f.operator)?.unary;
        if (unary) return { column: f.column, operator: f.operator };
        const type = this.page?.columns.find((c) => c.name === f.column)?.valueType ?? 'text';
        const text = typeof f.value === 'string' ? f.value : '';
        const textual = ['contains', 'startsWith', 'endsWith'].includes(f.operator);
        return { ...f, value: textual ? text : parseInput(text, type) };
      });
    const button = this.dataPane.querySelector<HTMLButtonElement>('button[title="Filter rows"]');
    if (button) button.classList.toggle('on', this.filters.length > 0);
    this.pageIndex = 0;
    void this.reload();
  }

  // ---------------------------------------------------------------------------
  // Editing

  private writable(): boolean {
    return this.connected && !this.db.readOnly && this.init.entityKind !== 'view';
  }

  private canEditCell(row: number, col: number): boolean {
    if (!this.writable() || !this.can('update') || !this.page) return false;
    const record = this.page.rows[row];
    const column = this.page.columns[col];
    const info = this.columnInfo(column.name);
    if (!record?.key || !info || info.generated) return false;
    if (this.schema?.schema.rowKey === 'key' && info.primaryKeyPosition > 0) return false;
    const value = record.values[col];
    return isInlineEditable(value) && !isMasked(value) && !isPartial(value);
  }

  private async update(row: number, column: string, value: WireValue): Promise<boolean> {
    const key = this.page?.rows[row]?.key;
    if (!key) return false;
    try {
      const result = await this.host.request<MutationResult & { cancelled?: boolean }>({ op: 'update', key, values: { [column]: value } });
      if (isCancelled(result)) return false;
      announce(`Saved ${column}`);
      await this.reload();
      return true;
    } catch (error) {
      this.showError(error);
      return false;
    }
  }

  private commitEdit(row: number, col: number, text: string): Promise<boolean> {
    const column = this.page!.columns[col];
    return this.update(row, column.name, parseInput(text, column.valueType));
  }

  private async deleteRow(row: number): Promise<void> {
    const record = this.page?.rows[row];
    if (!record?.key || !this.writable() || !this.can('delete')) return;
    const label = Object.entries(record.key)
      .map(([k, v]) => `${k} = ${JSON.stringify(toPlain(v))}`)
      .join(', ');
    try {
      const result = await this.host.request({ op: 'delete', key: record.key, label: `${this.table}: ${label}` });
      if (isCancelled(result)) return;
      announce('Deleted');
      await this.reload();
    } catch (error) {
      this.showError(error);
    }
  }

  /** Opens the SQL console; an empty editor gets a SELECT on this table to start from. */
  private async openQuery(): Promise<void> {
    try {
      await this.host.request({ op: 'openSql', sql: `SELECT * FROM ${sqlIdentifier(this.table)} LIMIT 50;` });
    } catch (error) {
      this.showError(error);
    }
  }

  private async clearTable(): Promise<void> {
    try {
      const result = await this.host.request({ op: 'clear' });
      if (!isCancelled(result)) await this.reload(true);
    } catch (error) {
      this.showError(error);
    }
  }

  private formColumns(): ColumnInfo[] {
    return (this.schema?.schema.columns ?? []).filter((c) => !c.generated);
  }

  private addRow(initial?: Record<string, WireValue>): void {
    if (!this.schema) return;
    showRowForm({
      title: initial ? `Duplicate ${this.recordNoun(false)}` : `Add ${this.recordNoun(false)} to ${this.table}`,
      columns: this.formColumns(),
      initial,
      submitLabel: 'Insert',
      onSubmit: async (values) => {
        try {
          await this.host.request<MutationResult>({ op: 'insert', values });
          announce('Inserted');
          await this.reload(true);
          return true;
        } catch (error) {
          throw error instanceof Error ? error : new Error(String(error));
        }
      },
    });
  }

  private duplicateRow(row: number): void {
    const record = this.page?.rows[row];
    if (!record || !this.page) return;
    const initial: Record<string, WireValue> = {};
    this.page.columns.forEach((c, i) => {
      const info = this.columnInfo(c.name);
      const value = record.values[i];
      // Keys and auto-assigned ids must be new; masked/truncated data can't be copied.
      if (!info || info.autoIncrement || (this.schema?.schema.rowKey === 'key' && info.primaryKeyPosition > 0)) return;
      if (isMasked(value) || isPartial(value) || (isTagged(value) && value.$type === 'blob')) return;
      initial[c.name] = value;
    });
    this.addRow(initial);
  }

  // ---------------------------------------------------------------------------
  // Values, copy, menus

  private openValue(row: number, col: number): void {
    const record = this.page?.rows[row];
    const column = this.page?.columns[col];
    if (!record || !column) return;
    const info = this.columnInfo(column.name);
    const key = record.key;
    const editable =
      this.writable() && this.can('update') && !!key && !!info && !info.generated && !isMasked(record.values[col]) &&
      !(this.schema?.schema.rowKey === 'key' && info.primaryKeyPosition > 0);
    this.valuePanel.show({
      column: column.name,
      valueType: column.valueType,
      value: record.values[col],
      editable,
      nullable: info?.nullable ?? true,
      loadFull: key ? (maxBytes) => this.host.request<FullValue>({ op: 'readValue', key, column: column.name, maxBytes }) : undefined,
      saveToFile: key ? () => void this.host.request({ op: 'saveValue', key, column: column.name }) : undefined,
      copy: (text) => void this.host.request({ op: 'copy', text, label: column.name }),
      save: (text) => this.update(row, column.name, text === null ? null : parseInput(text, column.valueType)),
    });
  }

  private copyCell(row: number, col: number): void {
    const value = this.page?.rows[row]?.values[col];
    if (value === undefined) return;
    const plain = toPlain(value);
    const text = plain === null ? '' : typeof plain === 'object' ? stringifyPlain(plain) : String(plain);
    void this.host.request({ op: 'copy', text, label: 'cell' });
  }

  private copyRowJson(row: number): void {
    const record = this.page?.rows[row];
    if (!record || !this.page) return;
    const names = this.page.columns.map((c) => c.name);
    void this.host.request({ op: 'copy', text: stringifyPlain(rowToObject(names, record.values)), label: 'row as JSON' });
  }

  private copyRowCsv(row: number): void {
    const record = this.page?.rows[row];
    if (!record) return;
    void this.host.request({ op: 'copy', text: record.values.map(csvField).join(','), label: 'row as CSV' });
  }

  private cellMenu(row: number, col: number, x: number, y: number): void {
    const record = this.page?.rows[row];
    const column = this.page?.columns[col];
    if (!record || !column) return;
    const info = this.columnInfo(column.name);
    const writable = this.writable() && !!record.key;
    const items: (MenuItem | 'separator')[] = [
      { label: 'Copy Cell', icon: 'copy', shortcut: `${modKey}C`, run: () => this.copyCell(row, col) },
      { label: 'Copy Row as JSON', icon: 'json', shortcut: `${modKey}⇧C`, run: () => this.copyRowJson(row) },
      { label: 'Copy Row as CSV', icon: 'list-flat', run: () => this.copyRowCsv(row) },
      'separator',
      { label: 'View Value', icon: 'eye', run: () => this.openValue(row, col) },
    ];
    if (writable && this.can('update')) {
      items.push(
        { label: 'Edit Cell', icon: 'edit', shortcut: 'Enter', disabled: !this.canEditCell(row, col), run: () => this.grid.beginEdit(row, col) },
        {
          label: 'Set NULL',
          icon: 'circle-slash',
          disabled: !this.canEditCell(row, col) || info?.nullable === false || record.values[col] === null,
          run: () => void this.update(row, column.name, null),
        },
      );
    }
    if (this.writable() && this.can('insert')) {
      items.push('separator', { label: `Duplicate ${this.recordNoun(false)}`, icon: 'copy', run: () => this.duplicateRow(row) });
    }
    if (writable && this.can('delete')) {
      items.push({ label: `Delete ${this.recordNoun(false)}…`, icon: 'trash', shortcut: 'Del', danger: true, run: () => void this.deleteRow(row) });
    }
    showMenu(x, y, items);
  }

  private onGlobalKey(e: KeyboardEvent): void {
    // App mode keeps one view per tab; only the visible one handles shortcuts.
    if (this.state.tab !== 'data' || !this.root.isConnected || this.root.offsetParent === null) return;
    if (isMod(e) && e.key.toLowerCase() === 'f' && this.can('search')) {
      e.preventDefault();
      this.searchInput.focus();
      this.searchInput.select();
    } else if ((isMod(e) && e.key.toLowerCase() === 'r') || e.key === 'F5') {
      e.preventDefault();
      void this.reload(true);
    } else if (e.key === 'Escape' && this.valuePanel.isOpen && !(e.target instanceof HTMLTextAreaElement)) {
      this.valuePanel.hide();
    }
  }

  // ---------------------------------------------------------------------------
  // Schema tab

  private renderSchema(): void {
    clear(this.schemaPane);
    const result = this.schema;
    if (!result) {
      this.schemaPane.appendChild(h('p', { class: 'muted' }, 'Loading…'));
      return;
    }
    const { schema } = result;
    const sensitive = new Set(result.sensitiveColumns);
    const yes = (b: boolean) => (b ? '✓' : '');

    const columns = h('table', { class: 'grid static', 'aria-label': 'Columns' });
    columns.appendChild(
      h('thead', {}, h('tr', {}, ...['Column', 'Type', 'Value type', 'PK', 'Nullable', 'Default', 'Notes'].map((t) => h('th', {}, t)))),
    );
    const body = h('tbody');
    for (const c of schema.columns) {
      const notes = [
        c.autoIncrement ? 'auto' : '',
        c.generated ? 'generated' : '',
        sensitive.has(c.name) ? 'masked' : '',
      ].filter(Boolean);
      body.appendChild(
        h(
          'tr',
          {},
          h('td', {}, c.primaryKeyPosition > 0 ? icon('key') : null, ` ${c.name}`),
          h('td', { class: 'mono' }, c.declaredType),
          h('td', {}, c.valueType),
          h('td', { class: 'center' }, c.primaryKeyPosition > 0 ? String(c.primaryKeyPosition) : ''),
          h('td', { class: 'center' }, c.nullable ? 'Yes' : 'No'),
          h('td', { class: 'mono' }, c.defaultValue ?? ''),
          h('td', { class: 'muted' }, notes.join(', ')),
        ),
      );
    }
    columns.appendChild(body);

    const section = (title: string, ...content: (Node | null)[]) =>
      h('section', { class: 'schema-section' }, h('h2', {}, title), ...content);

    const nouns = capitalize(recordNoun(schema.kind, true));
    const rowKey =
      schema.rowKey === 'rowid'
        ? `${nouns} are addressed by rowid.`
        : schema.rowKey === 'primaryKey'
          ? `${nouns} are addressed by the primary key.`
          : schema.rowKey === 'key'
            ? `${nouns} are addressed by their key.`
            : `${nouns} cannot be addressed individually (read-only).`;

    this.schemaPane.append(
      section(`${schema.columns.length} ${this.db.dataModel === 'relational' ? 'columns' : 'fields'}`, columns, h('p', { class: 'muted' }, rowKey)),
    );

    if (schema.foreignKeys.length) {
      const fk = h('table', { class: 'grid static' });
      fk.appendChild(h('thead', {}, h('tr', {}, ...['Columns', 'References', 'On update', 'On delete'].map((t) => h('th', {}, t)))));
      const tb = h('tbody');
      for (const f of schema.foreignKeys) {
        const link = h('a', { href: '#', on: { click: (e) => { e.preventDefault(); void this.host.request({ op: 'openTable', table: f.referencedTable }); } } },
          `${f.referencedTable}(${f.referencedColumns.join(', ')})`);
        tb.appendChild(h('tr', {}, h('td', {}, f.columns.join(', ')), h('td', {}, link), h('td', {}, f.onUpdate), h('td', {}, f.onDelete)));
      }
      fk.appendChild(tb);
      this.schemaPane.appendChild(section('Foreign keys', fk));
    }

    if (schema.indexes.length) {
      const ix = h('table', { class: 'grid static' });
      ix.appendChild(h('thead', {}, h('tr', {}, ...['Index', 'Columns', 'Unique', 'Origin'].map((t) => h('th', {}, t)))));
      const tb = h('tbody');
      for (const i of schema.indexes) {
        tb.appendChild(
          h('tr', { title: i.sql ?? '' }, h('td', {}, i.name), h('td', {}, i.columns.join(', ')), h('td', { class: 'center' }, yes(i.unique)),
            h('td', {}, i.origin === 'pk' ? 'primary key' : i.origin === 'u' ? 'UNIQUE constraint' : i.origin === 'c' ? 'CREATE INDEX' : (i.origin ?? ''))),
        );
      }
      ix.appendChild(tb);
      this.schemaPane.appendChild(section('Indexes', ix));
    }

    if (schema.triggers.length) {
      this.schemaPane.appendChild(
        section('Triggers', ...schema.triggers.map((t) => h('details', {}, h('summary', {}, t.name), h('pre', { class: 'code' }, t.sql ?? '')))),
      );
    }

    if (schema.sql) {
      this.schemaPane.appendChild(
        section(
          'Definition',
          h('div', { class: 'toolbar' }, button('Copy', () => void this.host.request({ op: 'copy', text: schema.sql!, label: 'definition' }), { icon: 'copy' })),
          h('pre', { class: 'code', tabindex: 0 }, schema.sql),
        ),
      );
    }
  }
}

function capitalize(s: string): string {
  return s ? s[0]!.toUpperCase() + s.slice(1) : s;
}

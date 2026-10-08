import type { InitMessage } from '@messages';
import type { SqlResult } from '@protocol/types';
import { formatCount, rowToObject, stringifyPlain, toPlain } from '@protocol/values';
import { announce, button, clear, h, icon, isMod, modKey, showMenu } from './dom';
import { DataGrid } from './grid';
import { HostError, isCancelled, type ViewHost } from './host';
import { ValuePanel } from './valuePanel';

interface SqlState {
  sql: string;
  widths: Record<string, number>;
}

/** SQL console: editor, run/cancel, results grid, timing and errors. */
export class SqlView {
  private readonly state: SqlState;
  private readonly editor = h('textarea', {
    class: 'sql-editor',
    'aria-label': 'SQL query',
    placeholder: `SELECT * FROM … LIMIT 50;\n\n${modKey}Enter runs the query (or the selection).`,
  });
  private readonly runButton = button('Run', () => void this.run(), { icon: 'play', primary: true, title: `Run (${modKey}Enter)` });
  private readonly cancelButton = button('Cancel', () => this.cancel(), { icon: 'debug-stop', disabled: true });
  private readonly status = h('div', { class: 'statusbar', 'aria-live': 'polite' });
  private readonly results = h('div', { class: 'data-body' });
  private readonly valuePanel = new ValuePanel(() => this.grid.focus());
  private readonly grid: DataGrid;
  private last?: SqlResult;
  private runSeq = 0;
  private running = false;

  constructor(
    private readonly init: InitMessage,
    private readonly host: ViewHost,
  ) {
    this.state = this.host.loadState<SqlState>({ sql: init.sql ?? '', widths: {} });
    this.editor.value = this.state.sql;
    this.grid = new DataGrid(
      {
        onOpenCell: (r, c) => this.openValue(r, c),
        onSelect: (r, c) => {
          if (this.valuePanel.isOpen) this.openValue(r, c);
        },
        onCopyCell: (r, c) => this.copyCell(r, c),
        onCopyRow: (r) => this.copyRow(r),
        onContextMenu: (r, c, x, y) =>
          showMenu(x, y, [
            { label: 'Copy Cell', icon: 'copy', shortcut: `${modKey}C`, run: () => this.copyCell(r, c) },
            { label: 'Copy Row as JSON', icon: 'json', shortcut: `${modKey}⇧C`, run: () => this.copyRow(r) },
            { label: 'View Value', icon: 'eye', run: () => this.openValue(r, c) },
          ]),
      },
      this.state.widths,
      (widths) => this.persist({ widths }),
      'Query results',
    );
  }

  mount(app: HTMLElement): void {
    this.editor.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && isMod(e)) {
        e.preventDefault();
        void this.run();
      } else if (e.key === 's' && isMod(e)) {
        e.preventDefault();
        void this.saveQuery();
      } else if (e.key === 'Tab' && !e.shiftKey) {
        e.preventDefault();
        this.editor.setRangeText('  ', this.editor.selectionStart, this.editor.selectionEnd, 'end');
      }
    });
    this.editor.addEventListener('input', () => this.persist({ sql: this.editor.value }));
    this.results.append(this.grid.element, this.valuePanel.element);
    app.appendChild(
      h(
        'div',
        { class: 'view sql-view' },
        h(
          'header',
          { class: 'view-header' },
          h('div', { class: 'title' }, icon('terminal'), h('h1', {}, 'SQL Console'), h('span', { class: 'badge' }, this.init.database.name)),
        ),
        h(
          'div',
          { class: 'toolbar main-toolbar', role: 'toolbar' },
          this.runButton,
          this.cancelButton,
          h('span', { class: 'toolbar-sep' }),
          button('Save Query', () => void this.saveQuery(), { icon: 'star-empty', title: `Save query (${modKey}S)` }),
          button('Copy results as JSON', () => this.copyAll(), { icon: 'json', iconOnly: true }),
          h('span', { class: 'spacer' }),
          h('span', { class: 'muted' }, `Reads return at most ${this.init.limits?.maxSqlRows ?? 100} rows · writes ask for confirmation`),
        ),
        this.editor,
        this.status,
        this.results,
      ),
    );
    this.editor.focus();
    if (this.init.runImmediately && this.editor.value.trim()) void this.run();
  }

  /** Fills the editor only if it is empty (never runs): keeps what the user typed. */
  suggestSql(sql: string): void {
    if (!this.editor.value.trim()) {
      this.editor.value = sql;
      this.persist({ sql });
    }
    this.editor.focus();
  }

  setSql(sql: string, run: boolean): void {
    this.editor.value = sql;
    this.persist({ sql });
    this.editor.focus();
    if (run) void this.run();
  }

  setConnection(state: string): void {
    this.runButton.disabled = state !== 'connected' || this.running;
  }

  private persist(patch: Partial<SqlState>): void {
    Object.assign(this.state, patch);
    this.host.saveState(this.state);
  }

  private selectedSql(): string {
    const { selectionStart, selectionEnd, value } = this.editor;
    const selected = selectionEnd > selectionStart ? value.slice(selectionStart, selectionEnd) : value;
    return selected.trim();
  }

  private async run(): Promise<void> {
    const sql = this.selectedSql();
    if (!sql || this.running) return;
    const seq = ++this.runSeq;
    this.running = true;
    this.runButton.disabled = true;
    this.cancelButton.disabled = false;
    clear(this.status);
    this.status.append(icon('sync~spin'), ' Executing query…');
    try {
      const result = await this.host.request<SqlResult & { cancelled?: boolean }>({ op: 'sql', sql });
      if (seq !== this.runSeq) return;
      if (isCancelled(result)) {
        clear(this.status);
        this.status.append(icon('circle-slash'), ' Not executed.');
        return;
      }
      this.show(result);
    } catch (error) {
      if (seq !== this.runSeq) return;
      clear(this.status);
      const code = error instanceof HostError ? `${error.code}: ` : '';
      const message = error instanceof Error ? error.message : String(error);
      this.status.append(h('span', { class: 'error-text', role: 'alert' }, icon('error'), ` ${code}${message}`));
      announce(message);
    } finally {
      if (seq === this.runSeq) {
        this.running = false;
        this.runButton.disabled = false;
        this.cancelButton.disabled = true;
      }
    }
  }

  /** The app can't abort a running statement; cancel stops waiting for it. */
  private cancel(): void {
    this.runSeq++;
    this.running = false;
    this.runButton.disabled = false;
    this.cancelButton.disabled = true;
    clear(this.status);
    this.status.append(icon('debug-stop'), ' Cancelled (the statement may still finish in the app).');
  }

  private show(result: SqlResult): void {
    this.last = result;
    clear(this.status);
    const time = `${result.elapsedMs.toFixed(1)} ms`;
    if (result.kind === 'write') {
      this.grid.setData([], []);
      this.status.append(
        icon('pass'),
        ` ${result.affectedRows === undefined ? 'Statement executed' : `${formatCount(result.affectedRows)} rows affected`}` +
          `${result.lastInsertId === undefined ? '' : ` · last insert id ${result.lastInsertId}`} · ${time}`,
      );
      announce('Statement executed');
      return;
    }
    this.grid.setData(
      result.columns.map((c) => ({ name: c.name, valueType: c.valueType })),
      result.rows.map((values) => ({ key: null, values })),
    );
    this.status.append(icon('pass'), ` ${formatCount(result.rowCount)} rows · ${time}`);
    if (result.truncated) {
      this.status.append(
        h('span', { class: 'warn-text' }, icon('warning'), ` Showing the first ${result.rowCount} rows — add LIMIT/OFFSET to page.`),
      );
    }
    announce(`${result.rowCount} rows`);
  }

  private openValue(row: number, col: number): void {
    const column = this.last?.columns[col];
    const value = this.last?.rows[row]?.[col];
    if (!column || value === undefined) return;
    this.valuePanel.show({
      column: column.name,
      valueType: column.valueType,
      value,
      editable: false,
      nullable: true,
      copy: (text) => void this.host.request({ op: 'copy', text, label: column.name }),
    });
  }

  private copyCell(row: number, col: number): void {
    const value = this.last?.rows[row]?.[col];
    if (value === undefined) return;
    const plain = toPlain(value);
    void this.host.request({ op: 'copy', text: plain === null ? '' : typeof plain === 'object' ? stringifyPlain(plain) : String(plain), label: 'cell' });
  }

  private copyRow(row: number): void {
    const values = this.last?.rows[row];
    if (!values || !this.last) return;
    void this.host.request({ op: 'copy', text: stringifyPlain(rowToObject(this.last.columns.map((c) => c.name), values)), label: 'row as JSON' });
  }

  private copyAll(): void {
    if (!this.last) return;
    const names = this.last.columns.map((c) => c.name);
    void this.host.request({ op: 'copy', text: stringifyPlain(this.last.rows.map((r) => rowToObject(names, r))), label: 'results as JSON' });
  }

  private async saveQuery(): Promise<void> {
    const sql = this.selectedSql();
    if (sql) await this.host.request({ op: 'saveQuery', sql });
  }
}

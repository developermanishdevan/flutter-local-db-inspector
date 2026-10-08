import type { RowKey, RowSort, ValueType, WireValue } from '@protocol/types';
import { displayCell, editText } from '@protocol/values';
import { clear, h, icon, isMod } from './dom';

export interface GridColumn {
  name: string;
  valueType: ValueType;
  declaredType?: string;
  primaryKey?: boolean;
  masked?: boolean;
}

export interface GridRow {
  key: RowKey | null;
  values: WireValue[];
}

export interface GridCallbacks {
  /** Header clicked; omitted when sorting is unsupported. */
  onSort?(column: string): void;
  canEdit?(row: number, col: number): boolean;
  /** Persists an inline edit; resolves `false` to keep the editor open. */
  onCommitEdit?(row: number, col: number, text: string): Promise<boolean>;
  onSelect?(row: number, col: number): void;
  /** Double-click/Enter on a cell that is not inline-editable. */
  onOpenCell?(row: number, col: number): void;
  onContextMenu?(row: number, col: number, x: number, y: number): void;
  onDeleteRow?(row: number): void;
  onCopyCell?(row: number, col: number): void;
  onCopyRow?(row: number): void;
}

const MIN_WIDTH = 48;
const DEFAULT_WIDTH = 160;

/**
 * Data grid for one page of results (≤ 100 rows, bounded by the protocol).
 * Implements the ARIA grid pattern: arrow keys move the active cell,
 * Enter/F2 edits, Escape cancels.
 */
export class DataGrid {
  readonly element: HTMLElement;
  private table = h('table', { class: 'grid', role: 'grid' });
  private columns: GridColumn[] = [];
  private rows: GridRow[] = [];
  private sort: RowSort[] = [];
  private rowOffset = 0;
  private active: { row: number; col: number } | null = null;
  private editing: { row: number; col: number; input: HTMLTextAreaElement | HTMLInputElement } | null = null;

  constructor(
    private readonly callbacks: GridCallbacks,
    private readonly widths: Record<string, number>,
    private readonly onWidthsChanged: (widths: Record<string, number>) => void,
    label: string,
  ) {
    this.table.setAttribute('aria-label', label);
    this.element = h('div', { class: 'grid-scroll', tabindex: 0 }, this.table);
    this.element.addEventListener('keydown', (e) => this.onKeyDown(e));
  }

  get selection(): { row: number; col: number } | null {
    return this.active;
  }

  get rowCount(): number {
    return this.rows.length;
  }

  setData(columns: GridColumn[], rows: GridRow[], sort: RowSort[] = [], rowOffset = 0): void {
    this.columns = columns;
    this.rows = rows;
    this.sort = sort;
    this.rowOffset = rowOffset;
    this.editing = null;
    if (this.active && (this.active.row >= rows.length || this.active.col >= columns.length)) this.active = null;
    this.render();
  }

  /** Replaces one row in place (after an edit). */
  updateRow(index: number, row: GridRow): void {
    this.rows[index] = row;
    const tr = this.table.tBodies[0]?.rows[index];
    if (!tr) return;
    row.values.forEach((value, col) => this.fillCell(tr.cells[col + 1], value, col));
  }

  focus(): void {
    this.element.focus();
  }

  private render(): void {
    clear(this.table);
    this.table.setAttribute('aria-rowcount', String(this.rows.length + 1));
    this.table.setAttribute('aria-colcount', String(this.columns.length + 1));

    const colgroup = h('colgroup', {}, h('col', { class: 'rownum-col' }));
    for (const c of this.columns) {
      const col = h('col');
      col.style.width = `${this.widths[c.name] ?? DEFAULT_WIDTH}px`;
      colgroup.appendChild(col);
    }
    this.table.appendChild(colgroup);

    const headRow = h('tr', { role: 'row' }, h('th', { class: 'rownum', role: 'columnheader', 'aria-label': 'Row number' }, '#'));
    this.columns.forEach((column, index) => headRow.appendChild(this.header(column, index)));
    this.table.appendChild(h('thead', {}, headRow));

    const body = h('tbody');
    this.rows.forEach((row, r) => {
      const tr = h('tr', { role: 'row' });
      tr.setAttribute('aria-rowindex', String(r + 2));
      tr.appendChild(h('th', { class: 'rownum', role: 'rowheader' }, String(this.rowOffset + r + 1)));
      row.values.forEach((value, c) => {
        const td = h('td', { role: 'gridcell' });
        td.setAttribute('aria-colindex', String(c + 2));
        this.fillCell(td, value, c);
        td.addEventListener('mousedown', (e) => {
          if (e.button === 0 && !this.isEditing(r, c)) this.setActive(r, c);
        });
        td.addEventListener('dblclick', () => this.beginEdit(r, c));
        td.addEventListener('contextmenu', (e) => {
          e.preventDefault();
          this.setActive(r, c);
          this.callbacks.onContextMenu?.(r, c, e.clientX, e.clientY);
        });
        tr.appendChild(td);
      });
      body.appendChild(tr);
    });
    this.table.appendChild(body);
    if (this.active) this.paintActive();
  }

  private header(column: GridColumn, index: number): HTMLElement {
    const sort = this.sort.find((s) => s.column === column.name);
    const th = h(
      'th',
      {
        role: 'columnheader',
        title: `${column.name}${column.declaredType ? ` ${column.declaredType}` : ''}${column.masked ? ' (masked)' : ''}`,
        'aria-sort': sort ? (sort.direction === 'asc' ? 'ascending' : 'descending') : 'none',
      },
      h(
        'div',
        { class: 'th-content' },
        column.primaryKey ? icon('key', 'Primary key') : null,
        column.masked ? icon('lock', 'Masked') : null,
        h('span', { class: 'th-name' }, column.name),
        h('span', { class: 'th-type' }, column.declaredType || column.valueType),
        sort ? icon(sort.direction === 'asc' ? 'arrow-up' : 'arrow-down') : null,
      ),
    );
    th.setAttribute('aria-colindex', String(index + 2));
    if (this.callbacks.onSort && !column.masked) {
      th.classList.add('sortable');
      th.tabIndex = -1;
      th.addEventListener('click', (e) => {
        if (!(e.target as HTMLElement).classList.contains('resizer')) this.callbacks.onSort?.(column.name);
      });
    }
    const resizer = h('div', { class: 'resizer', title: 'Drag to resize' });
    resizer.addEventListener('mousedown', (e) => this.startResize(e, column.name, index));
    resizer.addEventListener('dblclick', () => {
      delete this.widths[column.name];
      this.onWidthsChanged(this.widths);
      this.render();
    });
    th.appendChild(resizer);
    return th;
  }

  private startResize(e: MouseEvent, name: string, index: number): void {
    e.preventDefault();
    e.stopPropagation();
    const col = this.table.querySelectorAll('col')[index + 1] as HTMLTableColElement;
    const start = e.clientX;
    const initial = this.widths[name] ?? DEFAULT_WIDTH;
    document.body.classList.add('resizing');
    const move = (ev: MouseEvent) => {
      const width = Math.max(MIN_WIDTH, initial + ev.clientX - start);
      this.widths[name] = width;
      col.style.width = `${width}px`;
    };
    const up = () => {
      document.body.classList.remove('resizing');
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      this.onWidthsChanged(this.widths);
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  }

  private fillCell(td: HTMLTableCellElement, value: WireValue, col: number): void {
    const display = displayCell(value);
    clear(td);
    td.className = `cell cell-${display.kind}`;
    if (this.columns[col]?.valueType === 'integer' || this.columns[col]?.valueType === 'real') td.classList.add('numeric');
    td.title = display.title ?? (display.text.length > 40 ? display.text : '');
    td.textContent = display.text;
  }

  private cell(row: number, col: number): HTMLTableCellElement | undefined {
    return this.table.tBodies[0]?.rows[row]?.cells[col + 1];
  }

  private setActive(row: number, col: number): void {
    this.active = { row, col };
    this.paintActive();
    this.callbacks.onSelect?.(row, col);
  }

  private paintActive(): void {
    this.table.querySelector('.active')?.classList.remove('active');
    this.table.querySelector('tr.row-active')?.classList.remove('row-active');
    if (!this.active) return;
    const td = this.cell(this.active.row, this.active.col);
    if (!td) return;
    td.classList.add('active');
    td.parentElement?.classList.add('row-active');
    td.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  private isEditing(row: number, col: number): boolean {
    return this.editing?.row === row && this.editing.col === col;
  }

  beginEdit(row: number, col: number): void {
    if (this.editing) return;
    this.setActive(row, col);
    if (!this.callbacks.canEdit?.(row, col)) {
      this.callbacks.onOpenCell?.(row, col);
      return;
    }
    const td = this.cell(row, col);
    if (!td) return;
    const value = this.rows[row].values[col];
    const text = editText(value);
    const multiline = text.includes('\n');
    const input = multiline
      ? h('textarea', { class: 'cell-editor', 'aria-label': `Edit ${this.columns[col].name}` })
      : h('input', { class: 'cell-editor', type: 'text', 'aria-label': `Edit ${this.columns[col].name}` });
    input.value = text;
    if (value === null) input.placeholder = 'NULL';
    clear(td);
    td.classList.add('editing');
    td.appendChild(input);
    this.editing = { row, col, input };
    input.focus();
    input.select();
    (input as HTMLElement).addEventListener('keydown', (e: KeyboardEvent) => {
      e.stopPropagation();
      if (e.key === 'Escape') {
        e.preventDefault();
        this.cancelEdit();
      } else if (e.key === 'Enter' && (!multiline || isMod(e))) {
        e.preventDefault();
        void this.commitEdit();
      } else if (e.key === 'Tab') {
        e.preventDefault();
        void this.commitEdit().then((ok) => {
          if (ok) this.move(0, e.shiftKey ? -1 : 1);
        });
      }
    });
    input.addEventListener('blur', () => {
      // Clicking elsewhere keeps the user's text; commit only if changed.
      if (this.editing?.input === input) {
        if (input.value === text) this.cancelEdit();
        else void this.commitEdit();
      }
    });
  }

  private cancelEdit(): void {
    if (!this.editing) return;
    const { row, col } = this.editing;
    this.editing = null;
    const td = this.cell(row, col);
    if (td) this.fillCell(td, this.rows[row].values[col], col);
    this.paintActive();
    this.focus();
  }

  private async commitEdit(): Promise<boolean> {
    const editing = this.editing;
    if (!editing) return false;
    const { row, col, input } = editing;
    if (input.value === editText(this.rows[row].values[col]) && this.rows[row].values[col] !== null) {
      this.cancelEdit();
      return true;
    }
    input.disabled = true;
    const ok = (await this.callbacks.onCommitEdit?.(row, col, input.value)) ?? false;
    if (this.editing !== editing) return ok;
    if (ok) {
      this.editing = null;
      this.paintActive();
      this.focus();
    } else {
      input.disabled = false;
      input.focus();
    }
    return ok;
  }

  private move(dRow: number, dCol: number): void {
    if (this.rows.length === 0 || this.columns.length === 0) return;
    const current = this.active ?? { row: 0, col: 0 };
    const row = Math.min(this.rows.length - 1, Math.max(0, current.row + dRow));
    const col = Math.min(this.columns.length - 1, Math.max(0, current.col + dCol));
    this.setActive(row, col);
  }

  private onKeyDown(e: KeyboardEvent): void {
    if (this.editing) return;
    const active = this.active;
    switch (e.key) {
      case 'ArrowDown':
        this.move(1, 0);
        break;
      case 'ArrowUp':
        this.move(-1, 0);
        break;
      case 'ArrowRight':
        this.move(0, 1);
        break;
      case 'ArrowLeft':
        this.move(0, -1);
        break;
      case 'Home':
        this.move(0, -Infinity);
        break;
      case 'End':
        this.move(0, Infinity);
        break;
      case 'PageDown':
        this.move(10, 0);
        break;
      case 'PageUp':
        this.move(-10, 0);
        break;
      case 'Enter':
      case 'F2':
        if (active) this.beginEdit(active.row, active.col);
        break;
      case 'Delete':
      case 'Backspace':
        if (active) this.callbacks.onDeleteRow?.(active.row);
        break;
      case 'ContextMenu':
        if (active) {
          const rect = this.cell(active.row, active.col)?.getBoundingClientRect();
          if (rect) this.callbacks.onContextMenu?.(active.row, active.col, rect.left + 8, rect.bottom);
        }
        break;
      case 'c':
      case 'C':
        if (!isMod(e) || !active) return;
        if (e.shiftKey) this.callbacks.onCopyRow?.(active.row);
        else this.callbacks.onCopyCell?.(active.row, active.col);
        break;
      default:
        return;
    }
    e.preventDefault();
  }
}

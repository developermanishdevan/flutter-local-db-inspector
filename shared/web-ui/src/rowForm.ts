import type { ColumnInfo, WireValue } from '@protocol/types';
import { editText, parseInput } from '@protocol/values';
import { button, h } from './dom';

export interface RowFormOptions {
  title: string;
  columns: ColumnInfo[];
  initial?: Record<string, WireValue>;
  submitLabel: string;
  onSubmit(values: Record<string, WireValue>): Promise<boolean>;
}

/**
 * Modal form to add (or duplicate) a record. Generated columns are skipped;
 * auto-assigned keys may be left empty.
 */
export function showRowForm(options: RowFormOptions): void {
  document.querySelector('.dialog-backdrop')?.remove();
  const previouslyFocused = document.activeElement as HTMLElement | null;
  const fields: { column: ColumnInfo; input: HTMLInputElement | HTMLTextAreaElement; isNull: HTMLInputElement }[] = [];
  const error = h('p', { class: 'error-text', role: 'alert' });

  const form = h('form', { class: 'dialog', role: 'dialog', 'aria-label': options.title });
  form.appendChild(h('h2', {}, options.title));
  const grid = h('div', { class: 'form-grid' });
  for (const column of options.columns.filter((c) => !c.generated)) {
    const initial = options.initial?.[column.name];
    const multiline = column.valueType === 'json' || column.valueType === 'unknown';
    const input = multiline
      ? h('textarea', { class: 'input', 'aria-label': column.name })
      : h('input', { class: 'input', type: 'text', 'aria-label': column.name });
    input.value = initial === undefined ? '' : editText(initial);
    if (column.autoIncrement) input.placeholder = 'auto';
    else if (column.defaultValue !== undefined) input.placeholder = `default: ${column.defaultValue}`;
    const isNull = h('input', { type: 'checkbox', title: 'NULL', 'aria-label': `${column.name} is NULL` });
    isNull.checked = initial === null && !column.autoIncrement;
    isNull.disabled = !column.nullable;
    input.disabled = isNull.checked;
    isNull.addEventListener('change', () => {
      input.disabled = isNull.checked;
    });
    grid.append(
      h(
        'label',
        { class: 'form-label' },
        h('span', {}, column.name),
        h('span', { class: 'th-type' }, `${column.declaredType || column.valueType}${column.nullable ? '' : ' · required'}${column.primaryKeyPosition > 0 ? ' · key' : ''}`),
      ),
      input,
      h('label', { class: 'null-toggle', title: column.nullable ? 'Store NULL' : 'Not nullable' }, isNull, 'NULL'),
    );
    fields.push({ column, input, isNull });
  }
  form.appendChild(grid);
  form.appendChild(error);

  const close = () => {
    backdrop.remove();
    previouslyFocused?.focus();
  };
  const submit = h('button', { class: 'btn primary', type: 'submit' }, options.submitLabel);
  form.appendChild(h('div', { class: 'dialog-actions' }, button('Cancel', close), submit));
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const values: Record<string, WireValue> = {};
    for (const { column, input, isNull } of fields) {
      if (isNull.checked) {
        values[column.name] = null;
        continue;
      }
      if (input.value === '' && (column.autoIncrement || column.defaultValue !== undefined)) continue;
      values[column.name] = parseInput(input.value, column.valueType);
    }
    submit.disabled = true;
    error.textContent = '';
    void options.onSubmit(values).then(
      (ok) => {
        if (ok) close();
        else submit.disabled = false;
      },
      (e: unknown) => {
        error.textContent = e instanceof Error ? e.message : String(e);
        submit.disabled = false;
      },
    );
  });
  form.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      close();
    }
  });

  const backdrop = h('div', { class: 'dialog-backdrop' }, form);
  document.body.appendChild(backdrop);
  fields.find((f) => !f.input.disabled && !f.column.autoIncrement)?.input.focus();
}

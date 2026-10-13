import { entityIcon } from '@labels';
import type { EntitySummary } from '@protocol/types';
import { formatCount } from '@protocol/values';
import { clear, h, icon } from './dom';
import type { ViewHost } from './host';

/**
 * Table header "switch table" popover: a search box over the database's other
 * tables / collections / boxes. Picking one opens it (a new tab or panel).
 */
export function showTablePicker(anchor: HTMLElement, host: ViewHost, current: string): void {
  document.querySelector('.table-picker')?.remove();
  const input = h('input', {
    class: 'input',
    type: 'search',
    placeholder: 'Search tables…',
    'aria-label': 'Search tables',
  });
  const list = h('div', { class: 'table-picker-list', role: 'listbox', 'aria-label': 'Tables' });
  const popup = h('div', { class: 'table-picker', role: 'dialog', 'aria-label': 'Open another table' }, input, list);

  let entities: EntitySummary[] | undefined;
  let error: string | undefined;
  let matches: EntitySummary[] = [];
  let active = 0;

  const close = () => {
    popup.remove();
    document.removeEventListener('mousedown', outside, true);
    anchor.focus();
  };
  const outside = (e: MouseEvent) => {
    if (!popup.contains(e.target as Node) && !anchor.contains(e.target as Node)) close();
  };
  const pick = (entity: EntitySummary | undefined) => {
    if (!entity) return;
    close();
    void host.request({ op: 'openTable', table: entity.name });
  };

  const render = () => {
    clear(list);
    if (error) {
      list.append(h('div', { class: 'table-picker-message error-text' }, error));
      return;
    }
    if (!entities) {
      list.append(h('div', { class: 'table-picker-message muted' }, 'Loading…'));
      return;
    }
    const query = input.value.trim().toLowerCase();
    matches = entities.filter((e) => e.name !== current && (!query || e.name.toLowerCase().includes(query)));
    // Names that start with the query first, then alphabetical.
    matches.sort((a, b) => {
      const pa = query && a.name.toLowerCase().startsWith(query) ? 0 : 1;
      const pb = query && b.name.toLowerCase().startsWith(query) ? 0 : 1;
      return pa - pb || a.name.localeCompare(b.name);
    });
    active = Math.max(0, Math.min(active, matches.length - 1));
    if (!matches.length) {
      list.append(h('div', { class: 'table-picker-message muted' }, query ? 'No tables match.' : 'No other tables.'));
      return;
    }
    matches.forEach((entity, i) => {
      const item = h(
        'div',
        {
          class: `table-picker-item${i === active ? ' active' : ''}`,
          role: 'option',
          title: `${entity.name} — ${entity.kind}`,
          'aria-selected': String(i === active),
          on: {
            mousedown: (e) => e.preventDefault(),
            click: () => pick(entity),
            mousemove: () => {
              if (active !== i) {
                active = i;
                highlight();
              }
            },
          },
        },
        icon(entityIcon(entity.kind)),
        h('span', { class: 'table-picker-name' }, entity.name),
        h('span', { class: 'table-picker-desc' }, entity.kind),
        entity.rowCount !== undefined ? h('span', { class: 'table-picker-desc' }, formatCount(entity.rowCount)) : null,
      );
      list.appendChild(item);
    });
  };

  const highlight = () => {
    list.querySelectorAll<HTMLElement>('.table-picker-item').forEach((el, i) => {
      el.classList.toggle('active', i === active);
      el.setAttribute('aria-selected', String(i === active));
      if (i === active) el.scrollIntoView({ block: 'nearest' });
    });
  };

  input.addEventListener('input', () => {
    active = 0;
    render();
  });
  input.addEventListener('keydown', (e) => {
    switch (e.key) {
      case 'ArrowDown':
        active = Math.min(matches.length - 1, active + 1);
        highlight();
        break;
      case 'ArrowUp':
        active = Math.max(0, active - 1);
        highlight();
        break;
      case 'Enter':
        pick(matches[active]);
        break;
      case 'Escape':
        close();
        break;
      default:
        return;
    }
    e.preventDefault();
    e.stopPropagation();
  });

  const rect = anchor.getBoundingClientRect();
  popup.style.left = `${Math.max(4, Math.min(rect.left, window.innerWidth - 324))}px`;
  popup.style.top = `${rect.bottom + 4}px`;
  document.body.appendChild(popup);
  document.addEventListener('mousedown', outside, true);
  render();
  input.focus();

  host
    .request<EntitySummary[]>({ op: 'listTables' })
    .then((result) => {
      entities = result;
    })
    .catch((e: unknown) => {
      error = e instanceof Error ? e.message : String(e);
    })
    .finally(() => {
      if (popup.isConnected) render();
    });
}

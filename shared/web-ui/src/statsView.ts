import type { InitMessage } from '@messages';
import type { DatabaseStats } from '@protocol/types';
import { formatBytes, formatCount } from '@protocol/values';
import { button, clear, h, icon } from './dom';
import type { ViewHost } from './host';
import { entityGroupLabel, recordNoun } from '@labels';

/** Database statistics: size, entity/index counts and largest entities. */
export class StatsView {
  private readonly body = h('div', { class: 'stats-body' });

  constructor(
    private readonly init: InitMessage,
    private readonly host: ViewHost,
  ) {}

  mount(app: HTMLElement): void {
    app.appendChild(
      h(
        'div',
        { class: 'view' },
        h(
          'header',
          { class: 'view-header' },
          h('div', { class: 'title' }, icon('graph'), h('h1', {}, 'Statistics'), h('span', { class: 'badge' }, this.init.database.name)),
          button('Refresh', () => void this.load(), { icon: 'refresh', iconOnly: true }),
        ),
        this.body,
      ),
    );
    void this.load();
  }

  refresh(): void {
    void this.load();
  }

  private async load(): Promise<void> {
    clear(this.body);
    this.body.appendChild(h('p', { class: 'muted' }, 'Loading…'));
    let stats: DatabaseStats;
    try {
      stats = await this.host.request<DatabaseStats>({ op: 'stats' });
    } catch (error) {
      clear(this.body);
      this.body.appendChild(h('p', { class: 'error-text' }, icon('error'), ` ${error instanceof Error ? error.message : String(error)}`));
      return;
    }
    clear(this.body);
    // Word the tiles after the entities this engine actually has (tables,
    // collections, boxes, stores); views count with tables.
    const kinds = new Set(stats.entities.map((e) => (e.kind === 'view' ? 'table' : e.kind)));
    const model = this.init.database.dataModel;
    const kind = kinds.size === 1 ? [...kinds][0]! : model === 'relational' ? 'table' : model === 'keyValue' ? 'box' : 'collection';
    const entityLabel = kinds.size > 1 && model !== 'relational' ? 'Entities' : entityGroupLabel(kind);
    const recordLabel = capitalize(recordNoun(kind, true));
    const tile = (label: string, value: string) =>
      h('div', { class: 'tile' }, h('div', { class: 'tile-value' }, value), h('div', { class: 'tile-label' }, label));
    this.body.appendChild(
      h(
        'div',
        { class: 'tiles' },
        stats.sizeBytes !== undefined ? tile('Size', formatBytes(stats.sizeBytes)) : null,
        tile(entityLabel, formatCount(stats.entityCount)),
        this.init.database.capabilities.includes('indexes') ? tile('Indexes', formatCount(stats.indexCount)) : null,
        tile(recordLabel, formatCount(stats.totalRows)),
      ),
    );

    const sorted = [...stats.entities].sort((a, b) => (b.rowCount ?? 0) - (a.rowCount ?? 0));
    const max = Math.max(1, ...sorted.map((e) => e.rowCount ?? 0));
    const table = h('table', { class: 'grid static stats-table', 'aria-label': `Largest ${entityLabel.toLowerCase()}` });
    table.appendChild(h('thead', {}, h('tr', {}, h('th', {}, entityLabel.slice(0, -1)), h('th', {}, recordLabel), h('th', { 'aria-label': 'Share' }, ''))));
    const tbody = h('tbody');
    for (const e of sorted) {
      const bar = h('div', { class: 'bar' });
      bar.style.width = `${((e.rowCount ?? 0) / max) * 100}%`;
      const link = h('a', { href: '#', on: { click: (ev) => { ev.preventDefault(); void this.host.request({ op: 'openTable', table: e.name }); } } }, e.name);
      tbody.appendChild(
        h('tr', {}, h('td', {}, link, e.kind === 'view' ? h('span', { class: 'muted' }, ' view') : null),
          h('td', { class: 'numeric' }, e.rowCount === undefined ? '—' : formatCount(e.rowCount)),
          h('td', { class: 'bar-cell' }, bar)),
      );
    }
    table.appendChild(tbody);
    this.body.appendChild(h('h2', {}, `Largest ${entityLabel.toLowerCase()}`));
    this.body.appendChild(table);
  }
}

function capitalize(s: string): string {
  return s ? s[0]!.toUpperCase() + s.slice(1) : s;
}

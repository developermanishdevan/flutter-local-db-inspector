/** Storage interface satisfied by `vscode.Memento`. */
export interface KeyValueMemento {
  get<T>(key: string, defaultValue: T): T;
  update(key: string, value: unknown): PromiseLike<void>;
}

export interface HistoryEntry {
  id: string;
  sql: string;
  databaseId: string;
  databaseName: string;
  at: number;
  ok: boolean;
  elapsedMs?: number;
  rowCount?: number;
}

export interface SavedQuery {
  id: string;
  name: string;
  sql: string;
  /** Engine type the query was written for, e.g. `sqlite`. */
  databaseType?: string;
  createdAt: number;
  updatedAt?: number;
}

/** Saved queries of one app, keyed by its Dart package name. */
export interface SavedQueryGroup {
  app: string;
  queries: SavedQuery[];
}

/** Used when the VM does not tell the app's package name. */
export const UNKNOWN_APP = '(unknown app)';

const HISTORY_KEY = 'flutterDbInspector.history';
/** `Record<app, SavedQuery[]>`. */
const SAVED_BY_APP_KEY = 'flutterDbInspector.savedQueriesByApp';
/** 1.x: one list per workspace, not tied to an app. */
const LEGACY_SAVED_KEY = 'flutterDbInspector.savedQueries';

/**
 * Query history and saved queries, stored by the host (VS Code workspace /
 * global state, the page's storage in app mode), never inside the app's
 * database.
 *
 * Saved queries are kept per app (its Dart package name) in [savedMemento]
 * until the user deletes them; history stays in [memento].
 */
export class QueryStore {
  private listeners = new Set<() => void>();

  constructor(
    private readonly memento: KeyValueMemento,
    private readonly limit: () => number,
    private readonly savedMemento: KeyValueMemento = memento,
  ) {}

  onDidChange(listener: () => void): { dispose(): void } {
    this.listeners.add(listener);
    return { dispose: () => this.listeners.delete(listener) };
  }

  private changed(): void {
    for (const l of [...this.listeners]) l();
  }

  get history(): HistoryEntry[] {
    return this.memento.get<HistoryEntry[]>(HISTORY_KEY, []);
  }

  private get byApp(): Record<string, SavedQuery[]> {
    const value = this.savedMemento.get<Record<string, SavedQuery[]>>(SAVED_BY_APP_KEY, {});
    return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  }

  /** Saved queries of [app], sorted by name. */
  saved(app: string): SavedQuery[] {
    const list = this.byApp[app];
    return Array.isArray(list) ? list : [];
  }

  /** Every app with saved queries; [current] first, then by name. */
  savedGroups(current?: string): SavedQueryGroup[] {
    return Object.entries(this.byApp)
      .filter(([, queries]) => Array.isArray(queries) && queries.length > 0)
      .map(([app, queries]) => ({ app, queries }))
      .sort((a, b) => Number(b.app === current) - Number(a.app === current) || a.app.localeCompare(b.app));
  }

  async record(entry: Omit<HistoryEntry, 'id' | 'at'>): Promise<void> {
    const limit = this.limit();
    if (limit <= 0) return;
    const sql = entry.sql.trim();
    // Collapse consecutive duplicates of the same statement.
    const rest = this.history.filter((h) => !(h.sql.trim() === sql && h.databaseId === entry.databaseId));
    const next: HistoryEntry = { ...entry, sql, id: newId(), at: Date.now() };
    await this.memento.update(HISTORY_KEY, [next, ...rest].slice(0, limit));
    this.changed();
  }

  async deleteHistory(id: string): Promise<void> {
    await this.memento.update(HISTORY_KEY, this.history.filter((h) => h.id !== id));
    this.changed();
  }

  async clearHistory(): Promise<void> {
    await this.memento.update(HISTORY_KEY, []);
    this.changed();
  }

  /**
   * Saves [sql] as [name] for [app]. A query with the same name (ignoring
   * case) is replaced, keeping its id, so saving again updates it.
   */
  async save(app: string, name: string, sql: string, databaseType?: string): Promise<SavedQuery> {
    const trimmed = name.trim();
    const now = Date.now();
    const list = this.saved(app);
    const existing = list.find((q) => q.name.toLowerCase() === trimmed.toLowerCase());
    const query: SavedQuery = existing
      ? { ...existing, name: trimmed, sql: sql.trim(), databaseType: databaseType ?? existing.databaseType, updatedAt: now }
      : { id: newId(), name: trimmed, sql: sql.trim(), databaseType, createdAt: now };
    const next = [...list.filter((q) => q.id !== query.id), query].sort((a, b) => a.name.localeCompare(b.name));
    await this.savedMemento.update(SAVED_BY_APP_KEY, { ...this.byApp, [app]: next });
    this.changed();
    return query;
  }

  async deleteSaved(app: string, id: string): Promise<void> {
    const byApp = { ...this.byApp };
    const next = this.saved(app).filter((q) => q.id !== id);
    if (next.length) byApp[app] = next;
    else delete byApp[app];
    await this.savedMemento.update(SAVED_BY_APP_KEY, byApp);
    this.changed();
  }

  /** Moves 1.x saved queries (not tied to an app) to [app], once. */
  async adoptLegacySaved(app: string): Promise<void> {
    const legacy = this.memento.get<SavedQuery[]>(LEGACY_SAVED_KEY, []);
    if (!Array.isArray(legacy) || !legacy.length) return;
    const merged = [...this.saved(app)];
    for (const q of legacy) {
      if (!merged.some((m) => m.name.toLowerCase() === q.name.toLowerCase())) merged.push(q);
    }
    merged.sort((a, b) => a.name.localeCompare(b.name));
    await this.savedMemento.update(SAVED_BY_APP_KEY, { ...this.byApp, [app]: merged });
    await this.memento.update(LEGACY_SAVED_KEY, undefined);
    this.changed();
  }
}

function newId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

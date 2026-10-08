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
}

const HISTORY_KEY = 'flutterDbInspector.history';
const SAVED_KEY = 'flutterDbInspector.savedQueries';

/**
 * Query history and saved queries. Stored by VS Code (workspace state),
 * never inside the app's database.
 */
export class QueryStore {
  private listeners = new Set<() => void>();

  constructor(
    private readonly memento: KeyValueMemento,
    private readonly limit: () => number,
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

  get saved(): SavedQuery[] {
    return this.memento.get<SavedQuery[]>(SAVED_KEY, []);
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

  async save(name: string, sql: string, databaseType?: string): Promise<SavedQuery> {
    const query: SavedQuery = { id: newId(), name, sql: sql.trim(), databaseType, createdAt: Date.now() };
    await this.memento.update(SAVED_KEY, [...this.saved, query].sort((a, b) => a.name.localeCompare(b.name)));
    this.changed();
    return query;
  }

  async deleteSaved(id: string): Promise<void> {
    await this.memento.update(SAVED_KEY, this.saved.filter((q) => q.id !== id));
    this.changed();
  }
}

function newId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

import type { FullValue, OpenTarget, WebviewRequest } from '@messages';
import { recordNoun } from '@labels';
import { InspectorError, type DatabaseDescriptor, type EntityKind, type MutationResult, type SqlResult } from '@protocol/types';
import { bytesToBase64, formatCount, utf8Decode } from '@protocol/values';
import { exportEntity, type ExportFormat } from '@services/exporter';
import { InspectorClient } from '@services/inspectorClient';
import { QueryStore, type KeyValueMemento } from '@services/queryStore';
import { chooseDialog, confirmDialog, promptDialog } from './dialog';
import { HostError, isCancelled, request, scopedState, type ViewHost } from './host';

/**
 * App mode: the UI itself turns view requests into protocol calls and shows
 * confirmations; the host only forwards `call`s to the app and provides
 * clipboard / file / notification services.
 */

/** Sends protocol calls through the host; app errors keep their code and details. */
export const client = new InspectorClient({
  async request(method, params = {}) {
    try {
      return await request<Record<string, unknown>>({ op: 'call', method, params });
    } catch (error) {
      if (error instanceof HostError) throw new InspectorError(error.code, error.message, error.details);
      throw error;
    }
  },
});

/** History and saved queries, kept in the host page's storage (never in the app). */
function localMemento(prefix: string): KeyValueMemento {
  const memory = new Map<string, unknown>();
  return {
    get<T>(key: string, defaultValue: T): T {
      try {
        const raw = window.localStorage.getItem(prefix + key);
        if (raw !== null) return JSON.parse(raw) as T;
      } catch {
        // Storage blocked or corrupt.
      }
      return memory.has(key) ? (memory.get(key) as T) : defaultValue;
    },
    update(key: string, value: unknown): Promise<void> {
      memory.set(key, value);
      try {
        window.localStorage.setItem(prefix + key, JSON.stringify(value));
      } catch {
        // Storage blocked: memory only.
      }
      return Promise.resolve();
    },
  };
}

export interface AppSettings {
  confirmCellEdits: boolean;
  historyLimit: number;
}

export const settings: AppSettings = { confirmCellEdits: false, historyLimit: 100 };
export const queries = new QueryStore(localMemento('flutter_db_inspector.'), () => settings.historyLimit);

/** What views ask of the app shell. */
export interface ShellCallbacks {
  open(target: OpenTarget): void;
  /** Rows were added / removed: refresh tree counts. */
  dataChanged(databaseId: string): void;
  notify(message: string, level?: 'info' | 'warning' | 'error'): void;
}

const EXPORT_FORMATS: { id: ExportFormat; label: string; description: string }[] = [
  { id: 'json', label: 'JSON', description: 'array of objects' },
  { id: 'csv', label: 'CSV', description: 'header row + one line per record' },
  { id: 'sql', label: 'SQL', description: 'CREATE + INSERT statements' },
];

/** Re-throws protocol errors as HostError so views show "CODE: message". */
async function protocol<T>(work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (error) {
    if (error instanceof InspectorError) throw new HostError(error.code, error.message, error.details);
    throw error;
  }
}

/** Saves through the host; false when the user cancelled the dialog. */
async function saveFile(name: string, content: { text: string } | { base64: string }): Promise<boolean> {
  return !isCancelled(await request({ op: 'saveFile', name, ...content }));
}

function fileSafe(name: string): string {
  return name.replace(/[^\w.-]+/g, '_');
}

/**
 * A ViewHost for one tab: requests are scoped to [db] (and [table] for table
 * views), like a VS Code panel.
 */
export function viewHost(
  scope: string,
  db: () => DatabaseDescriptor,
  table: string | undefined,
  kind: EntityKind | undefined,
  shell: ShellCallbacks,
): ViewHost {
  const state = scopedState(scope);
  const noun = recordNoun(kind ?? 'table');
  const nouns = recordNoun(kind ?? 'table', true);
  const t = () => {
    if (!table) throw new HostError('INVALID_REQUEST', 'This view has no table');
    return table;
  };

  async function handle(req: WebviewRequest): Promise<unknown> {
    const d = db();
    switch (req.op) {
      case 'rows':
        return protocol(() => client.queryRows({ databaseId: d.id, table: t(), ...req.params }));
      case 'schema':
        return protocol(() => client.tableSchema(d.id, t()));
      case 'stats':
        return protocol(() => client.stats(d.id));
      case 'update': {
        if (settings.confirmCellEdits) {
          const ok = await confirmDialog({
            title: `Save changes to this ${noun}?`,
            message: `${t()}: ${Object.keys(req.values).join(', ')}`,
            okLabel: 'Save',
          });
          if (!ok) return { cancelled: true };
        }
        return protocol(() => client.updateRow(d.id, t(), req.key, req.values));
      }
      case 'insert': {
        const result = await protocol(() => client.insertRow(d.id, t(), req.values));
        shell.dataChanged(d.id);
        return result;
      }
      case 'delete': {
        const ok = await confirmDialog({
          title: `Delete this ${noun}?`,
          message: `This changes the running app's data in "${d.name}".`,
          code: req.label,
          okLabel: 'Delete',
          danger: true,
        });
        if (!ok) return { cancelled: true };
        const result = await protocol(() => client.deleteRow(d.id, t(), req.key));
        shell.dataChanged(d.id);
        return result;
      }
      case 'clear': {
        let count: number | undefined;
        try {
          count = await client.countRows({ databaseId: d.id, table: t() });
        } catch {
          // Count is informative only.
        }
        const ok = await confirmDialog({
          title: `Delete all ${count === undefined ? '' : `${formatCount(count)} `}${nouns} from ${t()}?`,
          message: `This changes the running app's data in "${d.name}" and cannot be undone.`,
          okLabel: 'Delete All',
          danger: true,
        });
        if (!ok) return { cancelled: true };
        const result = await protocol<MutationResult>(() => client.clearTable(d.id, t()));
        shell.dataChanged(d.id);
        shell.notify(`Deleted ${formatCount(result.affectedRows)} ${nouns} from ${t()}.`);
        return result;
      }
      case 'sql':
        return runSql(d, req.sql, shell);
      case 'readValue': {
        const full = await protocol(() => client.readFullValue(d.id, { table: t(), key: req.key, column: req.column }, { maxBytes: req.maxBytes }));
        const value: FullValue = full.isText
          ? { text: utf8Decode(full.bytes), isText: true, totalBytes: full.totalBytes, complete: full.complete }
          : { base64: bytesToBase64(full.bytes), isText: false, totalBytes: full.totalBytes, complete: full.complete };
        return value;
      }
      case 'saveValue': {
        const full = await protocol(() => client.readFullValue(d.id, { table: t(), key: req.key, column: req.column }));
        const name = `${fileSafe(t())}_${fileSafe(req.column)}.${full.isText ? 'txt' : 'bin'}`;
        const saved = await saveFile(name, full.isText ? { text: utf8Decode(full.bytes) } : { base64: bytesToBase64(full.bytes) });
        return saved ? {} : { cancelled: true };
      }
      case 'export':
        return exportTable(d, t(), kind, shell);
      case 'openTable':
        shell.open({ view: 'table', databaseId: d.id, table: req.table, tab: 'data' });
        return {};
      case 'openSql':
        shell.open({ view: 'sql', databaseId: d.id, sql: req.sql, suggest: true });
        return {};
      case 'saveQuery': {
        const name = await promptDialog({ title: 'Save query', label: 'Name', value: firstLine(req.sql), okLabel: 'Save' });
        if (!name) return { cancelled: true };
        await queries.save(name, req.sql, d.type);
        shell.notify(`Saved query "${name}".`);
        return {};
      }
      default:
        // copy, notify, saveFile, call: host services.
        return request(req);
    }
  }

  return {
    request: <T>(req: WebviewRequest) => handle(req) as Promise<T>,
    loadState: state.loadState,
    saveState: state.saveState,
  };
}

function firstLine(sql: string): string {
  const line = sql.trim().split('\n')[0] ?? '';
  return line.length > 40 ? `${line.slice(0, 40)}…` : line;
}

/** Runs SQL; writes are confirmed before being re-sent with `allowWrite`. */
async function runSql(db: DatabaseDescriptor, sql: string, shell: ShellCallbacks): Promise<SqlResult | { cancelled: true }> {
  const record = (ok: boolean, extra: { elapsedMs?: number; rowCount?: number } = {}) =>
    queries.record({ sql, databaseId: db.id, databaseName: db.name, ok, ...extra });
  try {
    let result: SqlResult;
    try {
      result = await client.executeSql(db.id, sql);
    } catch (error) {
      if (!(error instanceof InspectorError && error.requiresConfirmation)) throw error;
      const statement = String(error.details['statement'] ?? 'This statement');
      const ok = await confirmDialog({
        title: 'This query may modify application data.',
        message: `${statement} on "${db.name}":`,
        code: sql.length > 500 ? `${sql.slice(0, 500)}…` : sql,
        okLabel: 'Execute',
        danger: true,
      });
      if (!ok) return { cancelled: true };
      result = await client.executeSql(db.id, sql, { allowWrite: true });
      shell.dataChanged(db.id);
    }
    await record(true, { elapsedMs: result.elapsedMs, rowCount: result.rowCount });
    return result;
  } catch (error) {
    await record(false);
    if (error instanceof InspectorError) throw new HostError(error.code, error.message, error.details);
    throw error;
  }
}

/** Exports one entity to a file the user picks (format chosen first). */
export async function exportTable(
  db: DatabaseDescriptor,
  table: string,
  kind: EntityKind | undefined,
  shell: ShellCallbacks,
): Promise<unknown> {
  // INSERT statements only make sense for SQL databases.
  const formats = EXPORT_FORMATS.filter((f) => f.id !== 'sql' || db.dataModel === 'relational');
  const format = await chooseDialog({ title: `Export ${table}`, choices: formats, okLabel: 'Export…' });
  if (!format) return { cancelled: true };
  shell.notify(`Exporting ${table}…`);
  const chunks: string[] = [];
  const summary = await protocol(() =>
    exportEntity(client, {
      databaseId: db.id,
      table,
      format,
      write: (chunk) => {
        chunks.push(chunk);
        return Promise.resolve();
      },
    }),
  );
  const saved = await saveFile(`${fileSafe(table)}.${format}`, { text: chunks.join('') });
  if (!saved) return { cancelled: true };
  const nouns = recordNoun(kind ?? 'table', summary.rows !== 1);
  shell.notify(`Exported ${formatCount(summary.rows)} ${nouns} from ${table}.`);
  if (summary.maskedColumns.length) {
    shell.notify(`Sensitive columns were exported as null: ${summary.maskedColumns.join(', ')}`, 'warning');
  }
  return {};
}

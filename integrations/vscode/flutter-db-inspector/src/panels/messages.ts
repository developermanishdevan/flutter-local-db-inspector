/**
 * Messages between a host (VS Code extension, Android Studio plugin, DevTools
 * extension) and the shared web UI. The UI never talks to the app directly.
 *
 * Two modes:
 * - Panel mode (VS Code): one view per webview (`init.view` table/sql/stats);
 *   the host runs every request and confirms destructive ones natively.
 * - App mode (Android Studio, DevTools): one page with the database tree,
 *   tabs, SQL history and dialogs (`init.view` app). The UI sends raw protocol
 *   calls (`call`) and asks the host only for clipboard, file and notification
 *   services (`copy`, `saveFile`, `notify`).
 */
import type {
  DatabaseDescriptor,
  InspectorLimits,
  RowKey,
  RowsQueryParams,
  WireValue,
} from '../protocol/types';

export type ViewKind = 'table' | 'sql' | 'stats';
export type Theme = 'light' | 'dark';
export type TableTab = 'data' | 'schema';

export interface InitMessage {
  type: 'init';
  view: ViewKind;
  database: DatabaseDescriptor;
  table?: string;
  entityKind?: string;
  tab?: TableTab;
  pageSize: number;
  limits?: InspectorLimits;
  sql?: string;
  runImmediately?: boolean;
}

/** App mode: the whole inspector in one page. */
export interface AppInitMessage {
  type: 'init';
  view: 'app';
  /** Host name, shown in diagnostics (e.g. `android-studio`, `devtools`). */
  host: string;
  /** Default rows per page (the app's `limits.maxPageSize` still caps it). */
  pageSize: number;
  theme?: Theme;
  /** Ask before saving an edited cell (Android Studio setting). */
  confirmCellEdits?: boolean;
  /** Maximum SQL history entries per page load (0 disables history). */
  historyLimit?: number;
}

/** What app mode should show; sent by native actions (e.g. "SQL Console"). */
export interface OpenTarget {
  view: ViewKind;
  databaseId: string;
  table?: string;
  tab?: TableTab;
  sql?: string;
  /** `sql` is only a starting point: it never replaces text the user typed. */
  suggest?: boolean;
}

export interface HostError {
  code: string;
  message: string;
  /** Protocol error details (e.g. `requiresConfirmation`, `statement`). */
  details?: Record<string, unknown>;
}

export type HostMessage =
  | InitMessage
  | AppInitMessage
  | { type: 'result'; id: number; ok: true; result: unknown }
  | { type: 'result'; id: number; ok: false; error: HostError }
  | { type: 'refresh' }
  | { type: 'connection'; state: string; message?: string }
  /** `ifEmpty`: only fill an empty editor (a suggestion, never run). */
  | { type: 'setSql'; sql: string; run: boolean; ifEmpty?: boolean }
  | { type: 'showTab'; tab: TableTab }
  // App mode only:
  /** A protocol event from the app, e.g. `flutter_db_inspector.databasesChanged`. */
  | { type: 'event'; name: string; data?: unknown }
  | { type: 'theme'; theme: Theme }
  | { type: 'open'; target: OpenTarget }
  /** Reload the database list and every open view (native Refresh action). */
  | { type: 'reload' };

export type WebviewRequest =
  | { op: 'rows'; params: Omit<RowsQueryParams, 'databaseId' | 'table'> }
  | { op: 'schema' }
  | { op: 'update'; key: RowKey; values: Record<string, WireValue> }
  | { op: 'insert'; values: Record<string, WireValue> }
  | { op: 'delete'; key: RowKey; label: string }
  | { op: 'clear' }
  | { op: 'sql'; sql: string }
  | { op: 'readValue'; key: RowKey; column: string; maxBytes: number }
  | { op: 'saveValue'; key: RowKey; column: string }
  | { op: 'copy'; text: string; label?: string }
  | { op: 'export' }
  | { op: 'stats' }
  | { op: 'openTable'; table: string }
  | { op: 'saveQuery'; sql: string }
  /**
   * Opens the database's SQL console (table toolbar "Query"). [sql] is a
   * starting point for an empty editor; nothing runs until the user does.
   */
  | { op: 'openSql'; sql: string }
  // App mode only:
  /** Protocol passthrough: the host sends `method` to the app and returns its result. */
  | { op: 'call'; method: string; params: Record<string, unknown> }
  /** Saves a file chosen by the user; resolves `{cancelled: true}` when they cancel. */
  | { op: 'saveFile'; name: string; text?: string; base64?: string }
  | { op: 'notify'; message: string; level?: 'info' | 'warning' | 'error' };

export type WebviewMessage =
  | { type: 'ready' }
  | { type: 'request'; id: number; request: WebviewRequest }
  | { type: 'error'; message: string };

/** Result of `readValue`. */
export interface FullValue {
  text?: string;
  base64?: string;
  isText: boolean;
  totalBytes: number;
  complete: boolean;
}

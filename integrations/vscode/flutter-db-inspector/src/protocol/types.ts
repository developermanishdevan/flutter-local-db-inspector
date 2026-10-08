/**
 * Wire types of the Flutter DB Inspector protocol (v1).
 *
 * Mirrors `flutter_db_inspector_protocol` (Dart). Unknown enum values and
 * extra fields from newer runtimes must be tolerated, never rejected.
 */

export const PROTOCOL_VERSION = 1;
export const SUPPORTED_PROTOCOL_VERSIONS: readonly number[] = [1];
export const SERVICE_EXTENSION = 'ext.flutter_db_inspector.request';
export const SERVICE_EXTENSION_PARAM = 'request';
export const EVENT_DATABASES_CHANGED = 'flutter_db_inspector.databasesChanged';

export const Methods = {
  inspectorStatus: 'inspector.status',
  databaseList: 'database.list',
  databaseInfo: 'database.info',
  databaseStats: 'database.stats',
  schemaList: 'schema.list',
  schemaTable: 'schema.table',
  rowsQuery: 'rows.query',
  rowsCount: 'rows.count',
  rowInsert: 'row.insert',
  rowUpdate: 'row.update',
  rowDelete: 'row.delete',
  tableClear: 'table.clear',
  queryExecute: 'query.execute',
  valueRead: 'value.read',
} as const;

export const ErrorCodes = {
  invalidRequest: 'INVALID_REQUEST',
  unsupportedProtocolVersion: 'UNSUPPORTED_PROTOCOL_VERSION',
  inspectorDisabled: 'INSPECTOR_DISABLED',
  databaseNotFound: 'DATABASE_NOT_FOUND',
  tableNotFound: 'TABLE_NOT_FOUND',
  columnNotFound: 'COLUMN_NOT_FOUND',
  rowNotFound: 'ROW_NOT_FOUND',
  queryFailed: 'QUERY_FAILED',
  permissionDenied: 'PERMISSION_DENIED',
  writeNotAllowed: 'WRITE_NOT_ALLOWED',
  unsupportedOperation: 'UNSUPPORTED_OPERATION',
  queryTimeout: 'QUERY_TIMEOUT',
  resultTooLarge: 'RESULT_TOO_LARGE',
  databaseBusy: 'DATABASE_BUSY',
  internalError: 'INTERNAL_ERROR',
  // Client-side codes (never sent by the runtime).
  notConnected: 'NOT_CONNECTED',
  connectionLost: 'CONNECTION_LOST',
  clientTimeout: 'CLIENT_TIMEOUT',
} as const;

export type Capability =
  | 'read'
  | 'filter'
  | 'sort'
  | 'search'
  | 'insert'
  | 'update'
  | 'delete'
  | 'clear'
  | 'sql'
  | 'schema'
  | 'indexes'
  | 'transactions'
  | 'export'
  | 'import'
  | 'liveChanges'
  | (string & {});

export type DataModel = 'relational' | 'document' | 'keyValue' | (string & {});
export type EntityKind = 'table' | 'view' | 'collection' | 'box' | 'store' | (string & {});
export type RowKeyKind = 'rowid' | 'primaryKey' | 'key' | 'none' | (string & {});
export type ValueType =
  | 'null'
  | 'integer'
  | 'real'
  | 'text'
  | 'boolean'
  | 'blob'
  | 'dateTime'
  | 'json'
  | 'unknown'
  | (string & {});

export type InspectorMode = 'disabled' | 'readOnly' | 'fullAccess' | (string & {});

/** A JSON value as produced by the runtime's value codec. */
export type WireValue =
  | null
  | boolean
  | number
  | string
  | TaggedValue;

export type TaggedValue =
  | { $type: 'bigint'; value: string }
  | { $type: 'real'; value: string }
  | { $type: 'text'; preview: string; size: number; truncated: boolean }
  | { $type: 'blob'; size: number; preview: string; truncated: boolean; base64?: string }
  | { $type: 'dateTime'; value: string }
  | { $type: 'json'; value: unknown }
  | { $type: 'masked' }
  | { $type: 'unknown'; display: string };

export type RowKey = Record<string, WireValue>;

export interface InspectorLimits {
  defaultPageSize: number;
  maxPageSize: number;
  maxSqlRows: number;
  maxResponseBytes: number;
  queryTimeoutMs: number;
  textPreviewBytes: number;
  blobChunkBytes: number;
}

export interface InspectorStatus {
  protocolVersion: number;
  supportedVersions: number[];
  packageVersion: string;
  mode: InspectorMode;
  methods: string[];
  limits: InspectorLimits;
}

export interface DatabaseDescriptor {
  id: string;
  name: string;
  type: string;
  capabilities: Capability[];
  dataModel: DataModel;
  readOnly: boolean;
  isolateId?: string;
}

export interface DatabaseMetadata {
  engine: string;
  engineVersion?: string;
  path?: string;
  sizeBytes?: number;
  extra: Record<string, unknown>;
}

export interface EntitySummary {
  name: string;
  kind: EntityKind;
  rowCount?: number;
  readOnly: boolean;
}

export interface IndexInfo {
  name: string;
  table: string;
  columns: string[];
  unique: boolean;
  origin?: string;
  partial: boolean;
  sql?: string;
}

export interface TriggerInfo {
  name: string;
  table: string;
  sql?: string;
}

export interface SchemaOverview {
  entities: EntitySummary[];
  indexes: IndexInfo[];
  triggers: TriggerInfo[];
}

export interface ColumnInfo {
  name: string;
  valueType: ValueType;
  declaredType: string;
  nullable: boolean;
  primaryKeyPosition: number;
  defaultValue?: string;
  autoIncrement: boolean;
  generated: boolean;
}

export interface ForeignKeyInfo {
  columns: string[];
  referencedTable: string;
  referencedColumns: string[];
  onUpdate: string;
  onDelete: string;
}

export interface TableSchema {
  name: string;
  kind: EntityKind;
  columns: ColumnInfo[];
  rowKey: RowKeyKind;
  foreignKeys: ForeignKeyInfo[];
  indexes: IndexInfo[];
  triggers: TriggerInfo[];
  sql?: string;
}

export interface TableSchemaResult {
  schema: TableSchema;
  sensitiveColumns: string[];
}

export type FilterOperator =
  | 'equals'
  | 'notEquals'
  | 'contains'
  | 'startsWith'
  | 'endsWith'
  | 'greaterThan'
  | 'lessThan'
  | 'greaterOrEqual'
  | 'lessOrEqual'
  | 'isNull'
  | 'isNotNull';

export const FILTER_OPERATORS: readonly { id: FilterOperator; label: string; unary?: boolean }[] = [
  { id: 'equals', label: '=' },
  { id: 'notEquals', label: '≠' },
  { id: 'contains', label: 'contains' },
  { id: 'startsWith', label: 'starts with' },
  { id: 'endsWith', label: 'ends with' },
  { id: 'greaterThan', label: '>' },
  { id: 'lessThan', label: '<' },
  { id: 'greaterOrEqual', label: '≥' },
  { id: 'lessOrEqual', label: '≤' },
  { id: 'isNull', label: 'is null', unary: true },
  { id: 'isNotNull', label: 'is not null', unary: true },
];

export interface RowFilter {
  column: string;
  operator: FilterOperator;
  value?: WireValue;
}

export interface RowSort {
  column: string;
  direction: 'asc' | 'desc';
}

export interface RowsQueryParams {
  databaseId: string;
  table: string;
  page?: number;
  pageSize?: number;
  filters?: RowFilter[];
  sort?: RowSort[];
  search?: string;
}

export interface ResultColumn {
  name: string;
  valueType: ValueType;
  declaredType?: string;
}

export interface RowRecord {
  key: RowKey | null;
  values: WireValue[];
}

export interface RowsPage {
  columns: ResultColumn[];
  rows: RowRecord[];
  page: number;
  pageSize: number;
  total?: number;
}

export interface MutationResult {
  affectedRows: number;
  insertedKey?: RowKey;
}

export interface SqlResult {
  kind: 'read' | 'write';
  columns: ResultColumn[];
  rows: WireValue[][];
  rowCount: number;
  truncated: boolean;
  affectedRows?: number;
  lastInsertId?: number;
  elapsedMs: number;
}

export interface DatabaseStats {
  sizeBytes?: number;
  entityCount: number;
  indexCount: number;
  triggerCount: number;
  totalRows: number;
  entities: EntitySummary[];
}

export interface ValueChunk {
  base64: string;
  offset: number;
  length: number;
  totalBytes: number;
  isText: boolean;
  done: boolean;
}

export interface ProtocolError {
  code: string;
  message: string;
  details: Record<string, unknown>;
}

export interface InspectorRequest {
  version: number;
  requestId: string;
  method: string;
  params: Record<string, unknown>;
}

export type InspectorResponse =
  | { version: number; requestId: string; success: true; result: Record<string, unknown> }
  | { version: number; requestId: string; success: false; error: ProtocolError };

/** Error thrown by the client for protocol failures and connection issues. */
export class InspectorError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly details: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = 'InspectorError';
  }

  /** True when a write was refused only because it was not yet confirmed. */
  get requiresConfirmation(): boolean {
    return this.code === ErrorCodes.writeNotAllowed && this.details['requiresConfirmation'] === true;
  }
}

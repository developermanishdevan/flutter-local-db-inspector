import {
  Methods,
  type DatabaseDescriptor,
  type DatabaseMetadata,
  type DatabaseStats,
  type InspectorStatus,
  type MutationResult,
  type RowKey,
  type RowsPage,
  type RowsQueryParams,
  type SchemaOverview,
  type SqlResult,
  type TableSchemaResult,
  type ValueChunk,
  type WireValue,
} from '../protocol/types';
import { base64ToBytes, concatBytes } from '../protocol/values';

/** Anything that can send protocol requests (the connection manager). */
export interface RequestSender {
  request(method: string, params?: Record<string, unknown>): Promise<Record<string, unknown>>;
}

/**
 * Typed protocol client. Every UI surface talks to the app only through this
 * class — never through the VM service directly.
 */
export class InspectorClient {
  constructor(private readonly sender: RequestSender) {}

  private async call<T>(method: string, params: object = {}): Promise<T> {
    return (await this.sender.request(method, params as Record<string, unknown>)) as T;
  }

  status(): Promise<InspectorStatus> {
    return this.call(Methods.inspectorStatus);
  }

  async listDatabases(): Promise<DatabaseDescriptor[]> {
    const result = await this.call<{ databases: DatabaseDescriptor[] }>(Methods.databaseList);
    return result.databases;
  }

  databaseInfo(databaseId: string): Promise<{ database: DatabaseDescriptor; metadata: DatabaseMetadata }> {
    return this.call(Methods.databaseInfo, { databaseId });
  }

  stats(databaseId: string): Promise<DatabaseStats> {
    return this.call(Methods.databaseStats, { databaseId });
  }

  schema(databaseId: string): Promise<SchemaOverview> {
    return this.call(Methods.schemaList, { databaseId });
  }

  tableSchema(databaseId: string, table: string): Promise<TableSchemaResult> {
    return this.call(Methods.schemaTable, { databaseId, table });
  }

  queryRows(params: RowsQueryParams): Promise<RowsPage> {
    return this.call(Methods.rowsQuery, params);
  }

  async countRows(params: RowsQueryParams): Promise<number> {
    return (await this.call<{ count: number }>(Methods.rowsCount, params)).count;
  }

  insertRow(databaseId: string, table: string, values: Record<string, WireValue>): Promise<MutationResult> {
    return this.call(Methods.rowInsert, { databaseId, table, values });
  }

  updateRow(
    databaseId: string,
    table: string,
    key: RowKey,
    values: Record<string, WireValue>,
  ): Promise<MutationResult> {
    return this.call(Methods.rowUpdate, { databaseId, table, key, values });
  }

  deleteRow(databaseId: string, table: string, key: RowKey): Promise<MutationResult> {
    return this.call(Methods.rowDelete, { databaseId, table, key });
  }

  clearTable(databaseId: string, table: string): Promise<MutationResult> {
    return this.call(Methods.tableClear, { databaseId, table });
  }

  executeSql(
    databaseId: string,
    sql: string,
    options: { allowWrite?: boolean; maxRows?: number; arguments?: WireValue[] } = {},
  ): Promise<SqlResult> {
    return this.call(Methods.queryExecute, { databaseId, sql, ...options });
  }

  readValue(
    databaseId: string,
    ref: { table: string; key: RowKey; column: string; offset?: number; length?: number },
  ): Promise<ValueChunk> {
    return this.call(Methods.valueRead, { databaseId, ...ref });
  }

  /** Reads a complete large value by streaming `value.read` chunks. */
  async readFullValue(
    databaseId: string,
    ref: { table: string; key: RowKey; column: string },
    options: { maxBytes?: number; onProgress?: (read: number, total: number) => void; isCancelled?: () => boolean } = {},
  ): Promise<{ bytes: Uint8Array; isText: boolean; totalBytes: number; complete: boolean }> {
    const chunks: Uint8Array[] = [];
    let offset = 0;
    let total = 0;
    let isText = true;
    const max = options.maxBytes ?? Number.POSITIVE_INFINITY;
    for (;;) {
      const chunk = await this.readValue(databaseId, { ...ref, offset });
      total = chunk.totalBytes;
      isText = chunk.isText;
      const data = base64ToBytes(chunk.base64);
      chunks.push(data);
      offset += data.length;
      options.onProgress?.(offset, total);
      if (chunk.done || data.length === 0 || offset >= max || options.isCancelled?.()) break;
    }
    return { bytes: concatBytes(chunks), isText, totalBytes: total, complete: offset >= total };
  }
}

import type { InspectorClient } from './inspectorClient';
import type { ResultColumn, RowRecord, TableSchema, WireValue } from '../protocol/types';
import {
  bytesToBase64,
  csvField,
  isMasked,
  isPartial,
  isTagged,
  rowToObject,
  sqlIdentifier,
  sqlLiteral,
  stringifyPlain,
  utf8Decode,
} from '../protocol/values';

export type ExportFormat = 'json' | 'csv' | 'sql';

export interface ExportProgress {
  rows: number;
  total?: number;
}

export interface ExportOptions {
  databaseId: string;
  table: string;
  format: ExportFormat;
  /** Receives output text incrementally (keeps memory bounded). */
  write: (chunk: string) => Promise<void>;
  onProgress?: (progress: ExportProgress) => void;
  isCancelled?: () => boolean;
  /** Full values above this size are exported as their preview. */
  maxValueBytes?: number;
}

export interface ExportSummary {
  rows: number;
  maskedColumns: string[];
  truncatedValues: number;
  cancelled: boolean;
}

const PAGE_SIZE = 100;

/**
 * Streams an entity to JSON, CSV or SQL by paging through `rows.query`.
 * Truncated values are completed with `value.read`; masked values are
 * exported as `null` and reported.
 */
export async function exportEntity(client: InspectorClient, options: ExportOptions): Promise<ExportSummary> {
  const { databaseId, table, format, write } = options;
  const maxValueBytes = options.maxValueBytes ?? 16 * 1024 * 1024;
  let schema: TableSchema | undefined;
  if (format === 'sql') schema = (await client.tableSchema(databaseId, table)).schema;

  const masked = new Set<string>();
  let truncatedValues = 0;
  let rows = 0;
  let columns: ResultColumn[] = [];
  let first = true;

  if (format === 'json') await write('[\n');
  if (format === 'sql' && schema?.sql) await write(`${schema.sql.trim().replace(/;?$/, ';')}\n\n`);

  for (let page = 0; ; page++) {
    if (options.isCancelled?.()) break;
    const result = await client.queryRows({ databaseId, table, page, pageSize: PAGE_SIZE });
    if (page === 0) {
      columns = result.columns;
      if (format === 'csv') await write(`${columns.map((c) => csvField(c.name)).join(',')}\r\n`);
    }
    const names = columns.map((c) => c.name);
    let out = '';
    for (const row of result.rows) {
      const values = await completeValues(client, databaseId, table, names, row, maxValueBytes, (column) => {
        masked.add(column);
      });
      truncatedValues += values.filter(isPartial).length;
      switch (format) {
        case 'json':
          out += `${first ? '' : ',\n'}  ${stringifyPlain(rowToObject(names, values), 0)}`;
          break;
        case 'csv':
          out += `${values.map(csvField).join(',')}\r\n`;
          break;
        case 'sql': {
          const insertable = columns
            .map((c, i) => ({ c, v: values[i] ?? null }))
            .filter(({ c }) => !schema?.columns.find((s) => s.name === c.name)?.generated);
          out +=
            `INSERT INTO ${sqlIdentifier(table)} (${insertable.map(({ c }) => sqlIdentifier(c.name)).join(', ')}) ` +
            `VALUES (${insertable.map(({ v }) => sqlLiteral(v)).join(', ')});\n`;
          break;
        }
      }
      first = false;
      rows++;
    }
    if (out) await write(out);
    options.onProgress?.({ rows, total: result.total });
    if (result.rows.length < PAGE_SIZE) break;
  }
  if (format === 'json') await write(`${first ? '' : '\n'}]\n`);
  return { rows, maskedColumns: [...masked], truncatedValues, cancelled: options.isCancelled?.() ?? false };
}

async function completeValues(
  client: InspectorClient,
  databaseId: string,
  table: string,
  names: string[],
  row: RowRecord,
  maxValueBytes: number,
  onMasked: (column: string) => void,
): Promise<WireValue[]> {
  const values = [...row.values];
  for (let i = 0; i < values.length; i++) {
    const value = values[i];
    if (isMasked(value)) {
      onMasked(names[i]);
      values[i] = null;
      continue;
    }
    const isBlob = isTagged(value) && value.$type === 'blob';
    if ((isPartial(value) || isBlob) && row.key) {
      const size = isTagged(value) && 'size' in value ? value.size : 0;
      if (size > maxValueBytes) continue;
      const full = await client.readFullValue(databaseId, { table, key: row.key, column: names[i] });
      values[i] = full.isText
        ? utf8Decode(full.bytes)
        : { $type: 'blob', size: full.bytes.length, preview: '', truncated: false, base64: bytesToBase64(full.bytes) };
    }
  }
  return values;
}

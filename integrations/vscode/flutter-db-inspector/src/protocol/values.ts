/**
 * Pure helpers for protocol values, shared by the extension host and the
 * webview (no `vscode` or DOM imports).
 */
import type { TaggedValue, ValueType, WireValue } from './types';

export function isTagged(value: WireValue | undefined): value is TaggedValue {
  return typeof value === 'object' && value !== null && '$type' in value;
}

export function isMasked(value: WireValue): boolean {
  return isTagged(value) && value.$type === 'masked';
}

/** Value is a preview only (truncated text/blob); the full value needs `value.read`. */
export function isPartial(value: WireValue): boolean {
  return isTagged(value) && (value.$type === 'text' || value.$type === 'blob') && value.truncated;
}

/** Whether a cell can be edited inline without loss. */
export function isInlineEditable(value: WireValue): boolean {
  if (!isTagged(value)) return true;
  return value.$type === 'bigint' || value.$type === 'dateTime' || value.$type === 'json';
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value.toFixed(value >= 10 ? 0 : 1)} ${units[unit]}`;
}

export function formatCount(n: number | undefined): string {
  return n === undefined ? '' : n.toLocaleString('en-US');
}

export interface CellDisplay {
  text: string;
  /** CSS modifier: null, number, bool, masked, blob, json, partial, unknown. */
  kind: string;
  title?: string;
}

const MAX_CELL_CHARS = 300;

/** How a value is rendered in a grid cell. */
export function displayCell(value: WireValue): CellDisplay {
  if (value === null) return { text: 'NULL', kind: 'null' };
  switch (typeof value) {
    case 'boolean':
      return { text: String(value), kind: 'bool' };
    case 'number':
      return { text: String(value), kind: 'number' };
    case 'string':
      return value.length > MAX_CELL_CHARS
        ? { text: `${value.slice(0, MAX_CELL_CHARS)}…`, kind: 'text', title: `${value.length} characters` }
        : { text: value, kind: 'text' };
  }
  switch (value.$type) {
    case 'bigint':
    case 'real':
      return { text: value.value, kind: 'number' };
    case 'dateTime':
      return { text: value.value, kind: 'date' };
    case 'masked':
      return { text: '••••••••', kind: 'masked', title: 'Sensitive value (masked by the app)' };
    case 'text':
      return {
        text: `${value.preview.slice(0, MAX_CELL_CHARS)}…`,
        kind: 'partial',
        title: `Text, ${formatBytes(value.size)} (preview)`,
      };
    case 'blob':
      return { text: `BLOB ${formatBytes(value.size)}`, kind: 'blob' };
    case 'json': {
      const text = JSON.stringify(value.value);
      return {
        text: text.length > MAX_CELL_CHARS ? `${text.slice(0, MAX_CELL_CHARS)}…` : text,
        kind: 'json',
      };
    }
    case 'unknown':
      return { text: value.display, kind: 'unknown', title: 'Value has no JSON representation' };
    default:
      return { text: JSON.stringify(value), kind: 'unknown' };
  }
}

/** Marker for numbers that must be emitted verbatim (e.g. 64-bit integers). */
export class RawNumber {
  constructor(readonly text: string) {}
}

/**
 * Converts a wire value into a plain JSON-compatible value for copy/export.
 * Large integers become [RawNumber] so they survive serialization exactly.
 */
export function toPlain(value: WireValue): unknown {
  if (!isTagged(value)) return value;
  switch (value.$type) {
    case 'bigint':
      return new RawNumber(value.value);
    case 'real':
      return value.value; // NaN / Infinity have no JSON form
    case 'dateTime':
      return value.value;
    case 'json':
      return value.value;
    case 'text':
      return value.preview;
    case 'blob':
      return value.base64 ?? null;
    case 'masked':
      return null;
    case 'unknown':
      return value.display;
    default:
      return null;
  }
}

/** JSON.stringify that writes [RawNumber] values unquoted. */
export function stringifyPlain(value: unknown, indent = 2): string {
  const marker = '__fdi_raw_number__:';
  const json = JSON.stringify(
    value,
    (_key, v: unknown) => (v instanceof RawNumber ? `${marker}${v.text}` : v),
    indent,
  );
  return json.replace(new RegExp(`"${marker}(-?\\d+)"`, 'g'), '$1');
}

/** Builds a JSON object for a row. */
export function rowToObject(columns: readonly string[], values: readonly WireValue[]): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  columns.forEach((c, i) => (out[c] = toPlain(values[i] ?? null)));
  return out;
}

export function csvField(value: WireValue): string {
  const plain = toPlain(value);
  if (plain === null || plain === undefined) return '';
  const text =
    plain instanceof RawNumber
      ? plain.text
      : typeof plain === 'object'
        ? stringifyPlain(plain, 0)
        : String(plain);
  return /[",\r\n]/.test(text) || /^\s|\s$/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

export function sqlIdentifier(name: string): string {
  return `"${name.replace(/"/g, '""')}"`;
}

/** SQL literal for a wire value (blobs need `base64` filled in). */
export function sqlLiteral(value: WireValue): string {
  if (value === null) return 'NULL';
  switch (typeof value) {
    case 'boolean':
      return value ? '1' : '0';
    case 'number':
      return Number.isFinite(value) ? String(value) : 'NULL';
    case 'string':
      return `'${value.replace(/'/g, "''")}'`;
  }
  switch (value.$type) {
    case 'bigint':
      return value.value;
    case 'blob':
      return value.base64 === undefined ? 'NULL' : `X'${base64ToHex(value.base64)}'`;
    case 'json':
      return `'${JSON.stringify(value.value).replace(/'/g, "''")}'`;
    case 'dateTime':
    case 'real':
      return `'${value.value}'`;
    case 'text':
      return `'${value.preview.replace(/'/g, "''")}'`;
    default:
      return 'NULL';
  }
}

// Byte helpers that work in Node and in browsers (the shared web UI uses the
// same client and exporter as the extension).

export function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function concatBytes(chunks: readonly Uint8Array[]): Uint8Array {
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.length;
  }
  return out;
}

export function utf8Decode(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

export function base64ToHex(base64: string): string {
  const binary = atob(base64);
  let hex = '';
  for (let i = 0; i < binary.length; i++) hex += binary.charCodeAt(i).toString(16).padStart(2, '0');
  return hex.toUpperCase();
}

/** Text shown when editing a cell. */
export function editText(value: WireValue): string {
  if (value === null) return '';
  if (!isTagged(value)) return String(value);
  switch (value.$type) {
    case 'bigint':
    case 'real':
    case 'dateTime':
      return value.value;
    case 'json':
      return JSON.stringify(value.value, null, 2);
    default:
      return '';
  }
}

const SAFE = Number.MAX_SAFE_INTEGER;

/**
 * Converts user input into a wire value according to the column's type.
 * Input that does not fit the type is kept as text (SQLite and most
 * document stores accept it; the engine reports a clear error otherwise).
 */
export function parseInput(text: string, type: ValueType): WireValue {
  const trimmed = text.trim();
  switch (type) {
    case 'integer':
      if (/^-?\d+$/.test(trimmed)) {
        const n = Number(trimmed);
        return Math.abs(n) <= SAFE ? n : { $type: 'bigint', value: trimmed };
      }
      return text;
    case 'real':
      return trimmed !== '' && !Number.isNaN(Number(trimmed)) ? Number(trimmed) : text;
    case 'boolean':
      if (/^(true|1)$/i.test(trimmed)) return true;
      if (/^(false|0)$/i.test(trimmed)) return false;
      return text;
    case 'text':
    case 'dateTime':
      return text;
    default:
      return parseLoose(text);
  }
}

/** For untyped/JSON columns: JSON when it parses, otherwise plain text. */
export function parseLoose(text: string): WireValue {
  const trimmed = text.trim();
  if (trimmed === '') return text;
  try {
    const parsed: unknown = JSON.parse(trimmed);
    if (parsed === null || typeof parsed === 'boolean' || typeof parsed === 'string') return parsed;
    if (typeof parsed === 'number') {
      return Number.isSafeInteger(parsed) || !Number.isInteger(parsed)
        ? parsed
        : { $type: 'bigint', value: trimmed };
    }
    return { $type: 'json', value: parsed };
  } catch {
    return text;
  }
}

export function relativeTime(at: number, now = Date.now()): string {
  const seconds = Math.round((now - at) / 1000);
  if (seconds < 45) return 'just now';
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.round(hours / 24);
  return `${days} d ago`;
}

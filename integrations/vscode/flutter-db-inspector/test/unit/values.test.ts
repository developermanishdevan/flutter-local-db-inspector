import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  base64ToBytes,
  bytesToBase64,
  concatBytes,
  csvField,
  displayCell,
  isInlineEditable,
  parseInput,
  parseLoose,
  rowToObject,
  sqlLiteral,
  stringifyPlain,
  utf8Decode,
} from '../../src/protocol/values';

test('displayCell renders every wire type', () => {
  assert.deepEqual(displayCell(null), { text: 'NULL', kind: 'null' });
  assert.equal(displayCell(true).kind, 'bool');
  assert.equal(displayCell(42).text, '42');
  assert.equal(displayCell({ $type: 'bigint', value: '9007199254740993' }).text, '9007199254740993');
  assert.equal(displayCell({ $type: 'masked' }).kind, 'masked');
  assert.equal(displayCell({ $type: 'blob', size: 2048, preview: '', truncated: true }).text, 'BLOB 2.0 KB');
  assert.equal(displayCell({ $type: 'json', value: { a: 1 } }).text, '{"a":1}');
  assert.equal(displayCell({ $type: 'text', preview: 'abc', size: 50000, truncated: true }).kind, 'partial');
  assert.equal(displayCell('x'.repeat(1000)).text.length, 301);
});

test('parseInput follows the column type', () => {
  assert.equal(parseInput('42', 'integer'), 42);
  assert.deepEqual(parseInput('9007199254740993', 'integer'), { $type: 'bigint', value: '9007199254740993' });
  assert.equal(parseInput('abc', 'integer'), 'abc');
  assert.equal(parseInput('3.5', 'real'), 3.5);
  assert.equal(parseInput('true', 'boolean'), true);
  assert.equal(parseInput('0', 'boolean'), false);
  assert.equal(parseInput('007', 'text'), '007');
  assert.deepEqual(parseInput('{"a":[1]}', 'json'), { $type: 'json', value: { a: [1] } });
  assert.equal(parseInput('dark', 'json'), 'dark');
});

test('parseLoose keeps unparseable text and big integers', () => {
  assert.equal(parseLoose('hello'), 'hello');
  assert.equal(parseLoose('12'), 12);
  assert.equal(parseLoose('"12"'), '12');
  assert.equal(parseLoose('null'), null);
  assert.deepEqual(parseLoose('12345678901234567890'), { $type: 'bigint', value: '12345678901234567890' });
});

test('masked, truncated and blob values are not inline editable', () => {
  assert.equal(isInlineEditable('x'), true);
  assert.equal(isInlineEditable({ $type: 'masked' }), false);
  assert.equal(isInlineEditable({ $type: 'text', preview: '', size: 1, truncated: true }), false);
  assert.equal(isInlineEditable({ $type: 'blob', size: 1, preview: '', truncated: false }), false);
});

test('JSON copy keeps 64-bit integers exact', () => {
  const row = rowToObject(['id', 'big', 'tags', 'secret'], [
    1,
    { $type: 'bigint', value: '9007199254740993' },
    { $type: 'json', value: ['a'] },
    { $type: 'masked' },
  ]);
  assert.equal(stringifyPlain(row, 0), '{"id":1,"big":9007199254740993,"tags":["a"],"secret":null}');
});

test('CSV and SQL literals escape correctly', () => {
  assert.equal(csvField('a,b'), '"a,b"');
  assert.equal(csvField('say "hi"'), '"say ""hi"""');
  assert.equal(csvField(null), '');
  assert.equal(sqlLiteral("O'Brien"), "'O''Brien'");
  assert.equal(sqlLiteral(true), '1');
  assert.equal(sqlLiteral({ $type: 'bigint', value: '-5' }), '-5');
  assert.equal(sqlLiteral({ $type: 'blob', size: 2, preview: '', truncated: false, base64: 'AP8=' }), "X'00FF'");
});

test('byte helpers round-trip without Node Buffer (shared web UI)', () => {
  const bytes = new Uint8Array(70_000).map((_, i) => (i * 7) % 256);
  assert.deepEqual(base64ToBytes(bytesToBase64(bytes)), bytes);
  assert.equal(bytesToBase64(bytes), Buffer.from(bytes).toString('base64'));
  assert.deepEqual(concatBytes([new Uint8Array([1, 2]), new Uint8Array([]), new Uint8Array([3])]), new Uint8Array([1, 2, 3]));
  assert.equal(utf8Decode(base64ToBytes(Buffer.from('héllo ✓', 'utf8').toString('base64'))), 'héllo ✓');
});

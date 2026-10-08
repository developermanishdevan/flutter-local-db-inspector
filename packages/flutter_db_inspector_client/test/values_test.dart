import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:test/test.dart';

void main() {
  group('WireValue.fromJson', () {
    test('plain JSON values', () {
      expect(WireValue.fromJson(null), isA<WireNull>());
      expect(WireValue.fromJson(true), const WireBool(true));
      expect(WireValue.fromJson(42), const WireInt(42));
      expect(WireValue.fromJson(1.5), const WireDouble(1.5));
      expect(WireValue.fromJson('x'), const WireString('x'));
    });

    test('tagged values round-trip through toJson', () {
      final samples = <Object?>[
        {r'$type': 'bigint', 'value': '9007199254740993'},
        {r'$type': 'real', 'value': 'NaN'},
        {r'$type': 'text', 'preview': 'abc', 'size': 50000, 'truncated': true},
        {r'$type': 'blob', 'size': 3, 'preview': 'AQID', 'truncated': false},
        {r'$type': 'dateTime', 'value': '2024-05-01T10:30:00.000Z'},
        {
          r'$type': 'json',
          'value': {
            'a': [1, 2],
          },
        },
        {r'$type': 'masked'},
        {r'$type': 'unknown', 'display': 'Instance of Foo'},
      ];
      for (final json in samples) {
        expect(WireValue.fromJson(json).toJson(), json, reason: '$json');
      }
    });

    test('unknown tags are tolerated', () {
      final v = WireValue.fromJson({r'$type': 'vector', 'value': '1,2'});
      expect(v, isA<WireUnknown>());
    });

    test('flags', () {
      expect(const WireMasked().isMasked, isTrue);
      expect(
        WireValue.fromJson(
          {r'$type': 'text', 'preview': 'a', 'size': 9, 'truncated': true},
        ).isPartial,
        isTrue,
      );
      expect(const WireBlob(size: 2, truncated: true).isPartial, isTrue);
      expect(const WireNull().isNull, isTrue);
    });
  });

  group('display', () {
    CellDisplay d(Object? json) => WireValues.display(WireValue.fromJson(json));

    test('NULL, numbers, booleans', () {
      expect(d(null).text, 'NULL');
      expect(d(null).kind, CellKind.nullValue);
      expect(d(3).text, '3');
      expect(d(2.0).text, '2');
      expect(d(1.25).text, '1.25');
      expect(d(false).kind, CellKind.boolean);
    });

    test('bigint is exact', () {
      final cell = d({r'$type': 'bigint', 'value': '9007199254740993'});
      expect(cell.text, '9007199254740993');
      expect(cell.kind, CellKind.number);
    });

    test('masked, blob, truncated text, json', () {
      expect(d({r'$type': 'masked'}).text, '••••••••');
      expect(
        d({
          r'$type': 'blob',
          'size': 2 * 1024 * 1024,
          'preview': '',
          'truncated': true,
        }).text,
        'BLOB 2.0 MB',
      );
      final partial = d({r'$type': 'text', 'preview': 'Lorem', 'size': 56000});
      expect(partial.text, 'Lorem…');
      expect(partial.kind, CellKind.partial);
      expect(partial.tooltip, contains('55 KB'));
      expect(
        d({
          r'$type': 'json',
          'value': {
            'name': 'John',
            'tags': ['a']
          },
        }).text,
        '{"name":"John","tags":["a"]}',
      );
    });

    test('long text is clipped', () {
      final cell = d('x' * 400);
      expect(cell.text.length, WireValues.maxCellChars + 1);
      expect(cell.text, endsWith('…'));
      expect(cell.tooltip, '400 characters');
    });
  });

  group('parseInput', () {
    WireValue p(String text, DbValueType type) =>
        WireValues.parseInput(text, type);

    test('integers', () {
      expect(p('42', DbValueType.integer), const WireInt(42));
      expect(p(' -7 ', DbValueType.integer), const WireInt(-7));
      expect(
        p('9007199254740993', DbValueType.integer),
        const WireBigInt('9007199254740993'),
      );
      expect(p('abc', DbValueType.integer), const WireString('abc'));
    });

    test('reals', () {
      expect(p('1.5', DbValueType.real), const WireDouble(1.5));
      expect(p('5', DbValueType.real), const WireInt(5));
      expect(p('', DbValueType.real), const WireString(''));
      expect(p('x', DbValueType.real), const WireString('x'));
    });

    test('booleans', () {
      expect(p('TRUE', DbValueType.boolean), const WireBool(true));
      expect(p('0', DbValueType.boolean), const WireBool(false));
      expect(p('maybe', DbValueType.boolean), const WireString('maybe'));
    });

    test('text and dates are kept verbatim', () {
      expect(p(' 42 ', DbValueType.text), const WireString(' 42 '));
      expect(p('2024-01-01', DbValueType.dateTime),
          const WireString('2024-01-01'));
    });

    test('loose: JSON when it parses', () {
      expect(p('{"a":1}', DbValueType.json), const WireJson({'a': 1}));
      expect(p('[1,2]', DbValueType.unknown), const WireJson([1, 2]));
      expect(p('null', DbValueType.unknown), const WireNull());
      expect(p('"q"', DbValueType.unknown), const WireString('q'));
      expect(p('12345678901234567890', DbValueType.unknown),
          const WireBigInt('12345678901234567890'));
      expect(p('hello', DbValueType.unknown), const WireString('hello'));
    });
  });

  group('editing and copying', () {
    test('inline editability', () {
      expect(WireValues.isInlineEditable(const WireString('a')), isTrue);
      expect(WireValues.isInlineEditable(const WireBigInt('1')), isTrue);
      expect(WireValues.isInlineEditable(const WireJson({})), isTrue);
      expect(WireValues.isInlineEditable(const WireMasked()), isFalse);
      expect(WireValues.isInlineEditable(const WireBlob(size: 1)), isFalse);
      expect(
        WireValues.isInlineEditable(
            const WireTruncatedText(preview: 'a', size: 10)),
        isFalse,
      );
    });

    test('editText', () {
      expect(WireValues.editText(const WireNull()), '');
      expect(WireValues.editText(const WireJson({'a': 1})), '{\n  "a": 1\n}');
      expect(WireValues.editText(const WireBigInt('123')), '123');
    });

    test('row as JSON keeps big integers exact', () {
      final json = WireValues.encodeJson(
        WireValues.rowToObject(
          ['id', 'big', 'pw', 'tags'],
          [
            const WireInt(1),
            const WireBigInt('9007199254740993'),
            const WireMasked(),
            const WireJson(['a']),
          ],
        ),
      );
      expect(json, '{"id":1,"big":9007199254740993,"pw":null,"tags":["a"]}');
    });

    test('copyText', () {
      expect(WireValues.copyText(const WireNull()), '');
      expect(WireValues.copyText(const WireBigInt('-9007199254740993')),
          '-9007199254740993');
      expect(WireValues.copyText(const WireString('x')), 'x');
    });

    test('toRaw keeps big integers as BigInt', () {
      expect(WireValues.toRaw(const WireBigInt('9007199254740993')),
          BigInt.parse('9007199254740993'));
      expect(
        RowFilter(
          column: 'big',
          operator: FilterOperator.equals,
          value: WireValues.toRaw(const WireBigInt('9007199254740993')),
        ).toJson()['value'],
        {r'$type': 'bigint', 'value': '9007199254740993'},
      );
    });

    test('blob writes carry base64', () {
      final blob = WireBlob.bytes(Uint8List.fromList([1, 2, 3]));
      expect(blob.toJson(), {
        r'$type': 'blob',
        'base64': base64Encode([1, 2, 3])
      });
    });
  });

  group('formatting', () {
    test('bytes and counts', () {
      expect(WireValues.formatBytes(512), '512 B');
      expect(WireValues.formatBytes(1536), '1.5 KB');
      expect(WireValues.formatBytes(10 * 1024 * 1024), '10 MB');
      expect(WireValues.formatCount(1234567), '1,234,567');
      expect(WireValues.formatCount(-1000), '-1,000');
      expect(WireValues.formatCount(12), '12');
    });

    test('hex dump', () {
      final dump = WireValues.hexDump(List.generate(18, (i) => i + 60));
      expect(dump.split('\n'), hasLength(2));
      expect(dump, startsWith('00000000  3c 3d'));
      expect(dump, contains('<=>?'));
    });
  });
}

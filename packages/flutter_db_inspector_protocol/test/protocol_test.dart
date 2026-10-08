import 'dart:typed_data';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('envelope', () {
    test('request round-trips', () {
      final request = InspectorRequest.fromJson({
        'version': 1,
        'requestId': 'abc',
        'method': 'database.list',
        'params': {'x': 1},
      });
      expect(request.toJson(), {
        'version': 1,
        'requestId': 'abc',
        'method': 'database.list',
        'params': {'x': 1},
      });
    });

    test('missing method is INVALID_REQUEST', () {
      expect(
        () => InspectorRequest.fromJson({'params': <String, Object?>{}}),
        throwsA(isA<InspectorException>()
            .having((e) => e.code, 'code', ErrorCodes.invalidRequest)),
      );
      expect(
        () => InspectorRequest.fromJson('nope'),
        throwsA(isA<InspectorException>()),
      );
    });

    test('responses parse into sealed variants', () {
      final ok = InspectorResponse.fromJson({
        'requestId': '1',
        'success': true,
        'result': {'a': 1},
      });
      expect(ok, isA<InspectorSuccess>());
      final fail = InspectorResponse.fromJson({
        'requestId': '1',
        'success': false,
        'error': {'code': 'TABLE_NOT_FOUND', 'message': 'gone'},
      });
      expect((fail as InspectorFailure).error.code, 'TABLE_NOT_FOUND');
      expect(fail.toJson()['error'], {
        'code': 'TABLE_NOT_FOUND',
        'message': 'gone',
        'details': <String, Object?>{},
      });
    });
  });

  group('value codec', () {
    Object? enc(Object? v,
            [ValueEncodingOptions o = const ValueEncodingOptions()]) =>
        DbValueCodec.encode(v, o);

    test('primitives pass through', () {
      expect(enc(null), isNull);
      expect(enc(true), isTrue);
      expect(enc(42), 42);
      expect(enc(1.5), 1.5);
      expect(enc(''), '');
      expect(enc('héllo 🚀'), 'héllo 🚀');
    });

    test('unsafe integers become bigint', () {
      expect(enc(9007199254740993),
          {r'$type': 'bigint', 'value': '9007199254740993'});
      expect(DbValueCodec.decode(enc(9007199254740993)), 9007199254740993);
      expect(enc(-9007199254740993),
          {r'$type': 'bigint', 'value': '-9007199254740993'});
    });

    test('non-finite doubles', () {
      expect(enc(double.nan), {r'$type': 'real', 'value': 'NaN'});
      expect((DbValueCodec.decode(enc(double.infinity))! as double).isInfinite,
          isTrue);
    });

    test('long text is truncated on a character boundary', () {
      final text = '🚀' * 100; // 4 bytes each
      final encoded =
          enc(text, const ValueEncodingOptions(textPreviewBytes: 10))! as Map;
      expect(encoded[r'$type'], 'text');
      expect(encoded['size'], 400);
      expect(encoded['preview'], '🚀🚀');
      expect(encoded['truncated'], isTrue);
    });

    test('blobs carry size and a short preview', () {
      final encoded = enc(Uint8List.fromList(List.filled(100, 7)))! as Map;
      expect(encoded['size'], 100);
      expect(encoded['truncated'], isTrue);
      expect(
          DbValueCodec.decode({r'$type': 'blob', 'base64': 'AQID'}), [1, 2, 3]);
    });

    test('truncated adapter values report the full size', () {
      final encoded = enc(const TruncatedValue('abc', 5000))! as Map;
      expect(encoded, {
        r'$type': 'text',
        'preview': 'abc',
        'size': 5000,
        'truncated': true
      });
    });

    test('dates, json, masked and unknown objects', () {
      final date = DateTime.utc(2024, 1, 2, 3, 4, 5);
      expect(enc(date),
          {r'$type': 'dateTime', 'value': '2024-01-02T03:04:05.000Z'});
      expect(DbValueCodec.decode(enc(date)), date);
      expect(
          enc({
            'a': [1, 2]
          }),
          {
            r'$type': 'json',
            'value': {
              'a': [1, 2]
            },
          });
      expect(enc(const MaskedValue()), {r'$type': 'masked'});
      expect((enc(Object())! as Map)[r'$type'], 'unknown');
    });

    test('masked and truncated values cannot be written back', () {
      expect(
        () => DbValueCodec.decode({r'$type': 'masked'}),
        throwsA(isA<InspectorException>()),
      );
      expect(
        () => DbValueCodec.decode({r'$type': 'text', 'truncated': true}),
        throwsA(isA<InspectorException>()),
      );
    });
  });

  group('models', () {
    test('capabilities ignore unknown names', () {
      expect(
        DbCapability.parseAll(['read', 'teleport', 'sql']),
        {DbCapability.read, DbCapability.sql},
      );
    });

    test('unknown data models and kinds degrade gracefully', () {
      final d = DatabaseDescriptor.fromJson({
        'id': 'a',
        'name': 'a',
        'type': 'future',
        'capabilities': ['read'],
        'dataModel': 'graph',
      });
      expect(d.dataModel, DbDataModel.relational);
      expect(EntityKind.fromWire('hypercube'), EntityKind.table);
    });

    test('rows query parses filters with decoded values', () {
      final q = RowsQuery.fromJson({
        'table': 'users',
        'filters': [
          {
            'column': 'id',
            'operator': 'greaterThan',
            'value': {r'$type': 'bigint', 'value': '9007199254740993'},
          },
        ],
        'sort': [
          {'column': 'name', 'direction': 'desc'},
        ],
        'search': '  ',
      });
      expect(q.filters.single.value, 9007199254740993);
      expect(q.sort.single.direction, SortDirection.desc);
      expect(q.search, isNull);
      expect(
        () => RowsQuery.fromJson({
          'table': 't',
          'filters': [
            {'column': 'a', 'operator': 'like'},
          ],
        }),
        throwsA(isA<InspectorException>()),
      );
    });

    test('schema round-trips', () {
      const schema = TableSchema(
        name: 'users',
        kind: EntityKind.table,
        rowKey: RowKeyKind.rowid,
        columns: [
          ColumnInfo(
              name: 'id',
              valueType: DbValueType.integer,
              primaryKeyPosition: 1),
        ],
      );
      final parsed = TableSchema.fromJson(schema.toJson());
      expect(parsed.toJson(), schema.toJson());
      expect(parsed.columns.single.isPrimaryKey, isTrue);
    });
  });
}

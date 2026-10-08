import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:test/test.dart';

/// Records requests and answers from a script.
class ScriptedSender implements InspectorRequestSender {
  ScriptedSender(this.answer);

  final Object? Function(String method, JsonMap params) answer;
  final requests = <(String, JsonMap)>[];

  @override
  Future<JsonMap> request(String method, [JsonMap params = const {}]) async {
    requests.add((method, params));
    final result = answer(method, params);
    if (result is InspectorClientException) throw result;
    return result! as JsonMap;
  }
}

void main() {
  test('queryRows sends filters/sort/search and parses wire rows', () async {
    final sender = ScriptedSender((method, params) => {
          'columns': [
            {'name': 'id', 'valueType': 'integer', 'declaredType': 'INTEGER'},
            {'name': 'password', 'valueType': 'text'},
          ],
          'rows': [
            {
              'key': {'rowid': 999},
              'values': [
                999,
                {r'$type': 'masked'},
              ],
            },
            {
              'key': null,
              'values': [1, 'x'],
            },
          ],
          'page': 0,
          'pageSize': 5,
          'total': 11,
        });
    final client = InspectorClient(sender);
    final page = await client.queryRows(
      'app_database',
      'users',
      pageSize: 5,
      search: '  User 99 ',
      sort: const [RowSort(column: 'id', direction: SortDirection.desc)],
      filters: const [
        RowFilter(column: 'email', operator: FilterOperator.isNotNull),
      ],
    );
    final (method, params) = sender.requests.single;
    expect(method, Methods.rowsQuery);
    expect(params, {
      'databaseId': 'app_database',
      'table': 'users',
      'filters': [
        {'column': 'email', 'operator': 'isNotNull'},
      ],
      'sort': [
        {'column': 'id', 'direction': 'desc'},
      ],
      'search': 'User 99',
      'page': 0,
      'pageSize': 5,
    });
    expect(page.total, 11);
    expect(page.columns.first.valueType, DbValueType.integer);
    expect(page.rows.first.key, {'rowid': 999});
    expect(page.rows.first.values[1], const WireMasked());
    expect(page.rows.last.key, isNull);
  });

  test('writes send wire values and keys unchanged', () async {
    final sender = ScriptedSender((m, p) => {
          'affectedRows': 1,
          'insertedKey': {'rowid': 7},
        });
    final client = InspectorClient(sender);
    final inserted = await client.insertRow('db', 't', {
      'big': const WireBigInt('9007199254740993'),
      'n': const WireNull(),
    });
    expect(inserted.insertedKey, {'rowid': 7});
    await client.updateRow('db', 't', {
      'id': {r'$type': 'bigint', 'value': '9007199254740993'},
    }, {
      'name': const WireString('x'),
    });
    await client.deleteRow('db', 't', {'rowid': 1});
    await client.clearTable('db', 't');
    expect(sender.requests.map((r) => r.$1), [
      Methods.rowInsert,
      Methods.rowUpdate,
      Methods.rowDelete,
      Methods.tableClear,
    ]);
    expect(sender.requests[0].$2['values'], {
      'big': {r'$type': 'bigint', 'value': '9007199254740993'},
      'n': null,
    });
    expect(sender.requests[1].$2['key'], {
      'id': {r'$type': 'bigint', 'value': '9007199254740993'},
    });
  });

  test('executeSql parses read results', () async {
    final sender = ScriptedSender((m, p) => {
          'kind': 'read',
          'columns': [
            {'name': 'big_int', 'valueType': 'integer'},
          ],
          'rows': [
            [
              {r'$type': 'bigint', 'value': '9007199254740993'},
            ],
          ],
          'rowCount': 1,
          'truncated': true,
          'elapsedMs': 1.25,
        });
    final result = await InspectorClient(sender)
        .executeSql('db', 'SELECT big_int FROM edge_cases', maxRows: 10);
    expect(sender.requests.single.$2, {
      'databaseId': 'db',
      'sql': 'SELECT big_int FROM edge_cases',
      'maxRows': 10,
    });
    expect(result.kind, SqlStatementKind.read);
    expect(result.rows.single.single, const WireBigInt('9007199254740993'));
    expect(result.truncated, isTrue);
    expect(result.elapsedMs, 1.25);
  });

  test('requiresConfirmation and resend with allowWrite', () async {
    final sender = ScriptedSender((m, p) => p['allowWrite'] == true
        ? {'kind': 'write', 'affectedRows': 3, 'elapsedMs': 2}
        : const InspectorClientException(
            ErrorCodes.writeNotAllowed,
            'This statement may modify data',
            {'requiresConfirmation': true},
          ));
    final client = InspectorClient(sender);
    await expectLater(
      client.executeSql('db', 'DELETE FROM t'),
      throwsA(isA<InspectorClientException>()
          .having((e) => e.requiresConfirmation, 'confirm', isTrue)),
    );
    final done =
        await client.executeSql('db', 'DELETE FROM t', allowWrite: true);
    expect(done.kind, SqlStatementKind.write);
    expect(done.affectedRows, 3);
  });

  test('readFullValue streams chunks until done', () async {
    final data = Uint8List.fromList(List.generate(2500, (i) => i % 251));
    final sender = ScriptedSender((m, p) {
      final offset = p['offset']! as int;
      final length = (p['length'] as int?) ?? 1000;
      final end =
          (offset + (length > 1000 ? 1000 : length)).clamp(0, data.length);
      return {
        'base64': base64Encode(data.sublist(offset, end)),
        'offset': offset,
        'length': end - offset,
        'totalBytes': data.length,
        'isText': false,
        'done': end >= data.length,
      };
    });
    final client = InspectorClient(sender);
    final progress = <int>[];
    final full = await client.readFullValue(
      'db',
      table: 't',
      key: const {'rowid': 1},
      column: 'data',
      onProgress: (read, _) => progress.add(read),
    );
    expect(full.bytes, data);
    expect(full.complete, isTrue);
    expect(progress, [1000, 2000, 2500]);

    final partial = await client.readFullValue('db',
        table: 't', key: const {'rowid': 1}, column: 'data', maxBytes: 1500);
    expect(partial.bytes.length, 1500);
    expect(partial.complete, isFalse);
  });

  test('typed results of the remaining methods', () async {
    final sender = ScriptedSender((m, p) => switch (m) {
          Methods.databaseList => {
              'databases': [
                {
                  'id': 'prefs',
                  'name': 'prefs',
                  'type': 'shared_preferences',
                  'capabilities': ['read', 'update', 'future-cap'],
                  'dataModel': 'keyValue',
                  'readOnly': true,
                },
              ],
            },
          Methods.databaseInfo => {
              'database': {
                'id': 'db',
                'name': 'db',
                'type': 'sqlite',
                'capabilities': ['read'],
              },
              'metadata': {'engine': 'SQLite', 'engineVersion': '3.45'},
            },
          Methods.databaseStats => {
              'sizeBytes': 4096,
              'indexCount': 1,
              'entities': [
                {'name': 'users', 'kind': 'table', 'rowCount': 10},
                {'name': 'orders', 'kind': 'table', 'rowCount': 5},
              ],
            },
          Methods.schemaList => {
              'entities': [
                {'name': 'v', 'kind': 'view', 'readOnly': true},
              ],
            },
          Methods.schemaTable => {
              'schema': {
                'name': 'users',
                'kind': 'table',
                'rowKey': 'rowid',
                'columns': [
                  {
                    'name': 'id',
                    'valueType': 'integer',
                    'primaryKeyPosition': 1
                  },
                ],
              },
              'sensitiveColumns': ['password'],
            },
          Methods.rowsCount => {'count': 11},
          _ => {
              'protocolVersion': 1,
              'supportedVersions': [1],
              'methods': <String>[],
            },
        });
    final client = InspectorClient(sender);
    final dbs = await client.listDatabases();
    expect(dbs.single.dataModel, DbDataModel.keyValue);
    expect(dbs.single.capabilities, {DbCapability.read, DbCapability.update});
    expect((await client.databaseInfo('db')).metadata.engineVersion, '3.45');
    final stats = await client.stats('db');
    expect(stats.totalRows, 15);
    expect(stats.sizeBytes, 4096);
    expect((await client.schema('db')).entities.single.kind, EntityKind.view);
    final schema = await client.tableSchema('db', 'users');
    expect(schema.schema.rowKey, RowKeyKind.rowid);
    expect(schema.sensitiveColumns, {'password'});
    expect(await client.countRows('db', 'users', search: 'x'), 11);
    expect((await client.status()).protocolVersion, 1);
  });

  test('malformed results become MALFORMED_RESPONSE', () async {
    final client = InspectorClient(ScriptedSender((m, p) => {
          'databases': [42],
        }));
    await expectLater(
      client.listDatabases(),
      throwsA(isA<InspectorClientException>()
          .having((e) => e.code, 'code', ClientErrorCodes.malformedResponse)),
    );
  });
}

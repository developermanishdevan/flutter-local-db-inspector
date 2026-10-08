import 'dart:async';
import 'dart:convert';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:flutter_db_inspector_devtools/services/host.dart';

/// An in-memory app answering protocol requests, so widgets and controllers
/// are tested through the real [InspectorClient] parsing.
class FakeBackend implements InspectorRequestSender {
  FakeBackend({this.readOnly = false, this.capabilities}) {
    _seed();
  }

  final bool readOnly;
  final List<String>? capabilities;
  final requests = <(String, JsonMap)>[];

  /// Completes pending `query.execute` calls when set (to test cancel).
  Completer<void>? sqlGate;

  final users = <Map<String, Object?>>[];
  int _nextId = 1;

  void _seed() {
    for (var i = 1; i <= 60; i++) {
      users.add({
        'id': _nextId++,
        'name': 'User $i',
        'email': i % 10 == 0 ? null : 'user$i@example.com',
        'password': 'pw',
        'big': i == 1 ? {r'$type': 'bigint', 'value': '9007199254740993'} : i,
        'data': i == 1
            ? {
                r'$type': 'blob',
                'size': 2097152,
                'preview': base64Encode([1, 2, 3]),
                'truncated': true
              }
            : null,
        'notes': i == 2
            ? {
                r'$type': 'text',
                'preview': 'Lorem',
                'size': 56000,
                'truncated': true
              }
            : 'n$i',
        'meta': i == 3
            ? {
                r'$type': 'json',
                'value': {'a': 1}
              }
            : null,
      });
    }
  }

  List<String> calls(String method) => [
        for (final r in requests)
          if (r.$1 == method) jsonEncode(r.$2)
      ];

  static const _columns = [
    {
      'name': 'id',
      'valueType': 'integer',
      'declaredType': 'INTEGER',
      'primaryKeyPosition': 1,
      'autoIncrement': true,
      'nullable': false
    },
    {
      'name': 'name',
      'valueType': 'text',
      'declaredType': 'TEXT',
      'nullable': false
    },
    {'name': 'email', 'valueType': 'text', 'declaredType': 'TEXT'},
    {'name': 'password', 'valueType': 'text', 'declaredType': 'TEXT'},
    {'name': 'big', 'valueType': 'integer', 'declaredType': 'INTEGER'},
    {'name': 'data', 'valueType': 'blob', 'declaredType': 'BLOB'},
    {'name': 'notes', 'valueType': 'text', 'declaredType': 'TEXT'},
    {'name': 'meta', 'valueType': 'json', 'declaredType': 'JSON'},
  ];

  static const columnNames = [
    'id',
    'name',
    'email',
    'password',
    'big',
    'data',
    'notes',
    'meta'
  ];

  Object? _wire(Map<String, Object?> row, String column) =>
      column == 'password' ? {r'$type': 'masked'} : row[column];

  @override
  Future<JsonMap> request(String method, [JsonMap params = const {}]) async {
    requests.add((method, params));
    await Future<void>.delayed(Duration.zero);
    switch (method) {
      case Methods.databaseList:
        return {
          'databases': [
            {
              'id': 'app',
              'name': 'app_database',
              'type': 'sqlite',
              'dataModel': 'relational',
              'readOnly': readOnly,
              'capabilities': capabilities ??
                  [
                    'read',
                    'filter',
                    'sort',
                    'search',
                    'insert',
                    'update',
                    'delete',
                    'clear',
                    'sql',
                    'schema',
                    'indexes'
                  ],
            },
            {
              'id': 'prefs',
              'name': 'prefs',
              'type': 'shared_preferences',
              'dataModel': 'keyValue',
              'capabilities': ['read', 'update'],
            },
          ],
        };
      case Methods.schemaList:
        if (params['databaseId'] == 'prefs') {
          return {
            'entities': [
              {'name': 'prefs', 'kind': 'store', 'rowCount': 3},
            ],
          };
        }
        return {
          'entities': [
            {
              'name': 'active_users',
              'kind': 'view',
              'rowCount': 40,
              'readOnly': true
            },
            {'name': 'users', 'kind': 'table', 'rowCount': users.length},
          ],
          'indexes': [
            {
              'name': 'idx_users_name',
              'table': 'users',
              'columns': ['name']
            },
          ],
          'triggers': <Object?>[],
        };
      case Methods.schemaTable:
        return {
          'schema': {
            'name': params['table'],
            'kind': params['table'] == 'active_users' ? 'view' : 'table',
            'rowKey': params['table'] == 'active_users' ? 'none' : 'rowid',
            'columns': _columns,
            'indexes': [
              {
                'name': 'idx_users_name',
                'table': 'users',
                'columns': ['name'],
                'origin': 'c'
              },
            ],
            'sql': 'CREATE TABLE users (id INTEGER PRIMARY KEY, …)',
          },
          'sensitiveColumns': ['password'],
        };
      case Methods.rowsQuery:
        var rows = [...users];
        final search = params['search'] as String?;
        if (search != null) {
          rows = rows.where((r) => '${r['name']}'.contains(search)).toList();
        }
        final sort = (params['sort'] as List?)?.cast<Map<String, Object?>>();
        if (sort != null && sort.isNotEmpty) {
          final column = sort.first['column']! as String;
          final desc = sort.first['direction'] == 'desc';
          rows.sort((a, b) {
            final c = '${a[column]}'.compareTo('${b[column]}');
            return desc ? -c : c;
          });
        }
        final page = params['page'] as int? ?? 0;
        final size = params['pageSize'] as int? ?? 50;
        final slice = rows.skip(page * size).take(size).toList();
        return {
          'columns': [
            for (final c in _columns)
              {'name': c['name'], 'valueType': c['valueType']},
          ],
          'rows': [
            for (final r in slice)
              {
                'key': params['table'] == 'active_users'
                    ? null
                    : {'rowid': r['id']},
                'values': [for (final c in columnNames) _wire(r, c)],
              },
          ],
          'page': page,
          'pageSize': size,
          'total': rows.length,
        };
      case Methods.rowUpdate:
        _write();
        final id = (params['key']! as Map)['rowid'];
        final row = users.firstWhere((r) => r['id'] == id);
        row.addAll((params['values']! as Map).cast<String, Object?>());
        return {'affectedRows': 1};
      case Methods.rowDelete:
        _write();
        final id = (params['key']! as Map)['rowid'];
        users.removeWhere((r) => r['id'] == id);
        return {'affectedRows': 1};
      case Methods.rowInsert:
        _write();
        final id = _nextId++;
        users.add(
            {...(params['values']! as Map).cast<String, Object?>(), 'id': id});
        return {
          'affectedRows': 1,
          'insertedKey': {'rowid': id},
        };
      case Methods.tableClear:
        _write();
        final n = users.length;
        users.clear();
        return {'affectedRows': n};
      case Methods.queryExecute:
        final gate = sqlGate;
        if (gate != null) await gate.future;
        final sql = params['sql']! as String;
        if (!sql.toUpperCase().startsWith('SELECT')) {
          if (params['allowWrite'] != true) {
            throw const InspectorClientException(
              ErrorCodes.writeNotAllowed,
              'This statement may modify data',
              {'requiresConfirmation': true},
            );
          }
          return {'kind': 'write', 'affectedRows': 2, 'elapsedMs': 1.5};
        }
        if (sql.contains('nope')) {
          throw const InspectorClientException(
              ErrorCodes.queryFailed, 'no such table: nope');
        }
        return {
          'kind': 'read',
          'columns': [
            {'name': 'big', 'valueType': 'integer'},
          ],
          'rows': [
            [
              {r'$type': 'bigint', 'value': '9007199254740993'},
            ],
          ],
          'rowCount': 1,
          'truncated': true,
          'elapsedMs': 0.5,
        };
      case Methods.valueRead:
        final bytes = utf8.encode('Lorem ipsum full value');
        return {
          'base64': base64Encode(bytes),
          'offset': 0,
          'length': bytes.length,
          'totalBytes': bytes.length,
          'isText': params['column'] == 'notes',
          'done': true,
        };
      case Methods.databaseStats:
        return {
          'sizeBytes': 8192,
          'indexCount': 1,
          'entities': [
            {'name': 'users', 'kind': 'table', 'rowCount': users.length},
            {'name': 'active_users', 'kind': 'view', 'rowCount': 40},
          ],
        };
      case Methods.databaseInfo:
        return {
          'database': {
            'id': 'app',
            'name': 'app_database',
            'type': 'sqlite',
            'capabilities': ['read']
          },
          'metadata': {'engine': 'SQLite', 'engineVersion': '3.45.0'},
        };
    }
    throw InspectorClientException(ErrorCodes.unsupportedOperation, method);
  }

  void _write() {
    if (readOnly) {
      throw const InspectorClientException(
          ErrorCodes.writeNotAllowed, 'Read-only');
    }
  }
}

/// Records clipboard writes.
class FakeHost implements InspectorHost {
  final copied = <String>[];
  final notifications = <String>[];

  @override
  void copyToClipboard(String text, {String what = 'value'}) =>
      copied.add(text);

  @override
  void notify(String message) => notifications.add(message);
}

/// A connected snapshot for controller tests.
ValueNotifier<ConnectionSnapshot> connectedSnapshot() => ValueNotifier(
      const ConnectionSnapshot(
        state: InspectorConnectionState.connected,
        isolateId: 'isolates/1',
        status: InspectorStatus(
          protocolVersion: 1,
          supportedVersions: [1],
          packageVersion: '0.1.0',
          mode: InspectorMode.fullAccess,
          methods: [],
          limits: InspectorLimits(),
        ),
      ),
    );

/// Wraps [child] in the DevTools theme.
Widget themed(Widget child, {bool dark = false}) => MaterialApp(
      theme: themeFor(
        isDarkTheme: dark,
        ideTheme: IdeTheme(),
        theme: ThemeData(
            useMaterial3: true,
            colorScheme: dark ? darkColorScheme : lightColorScheme),
      ),
      home: Scaffold(body: child),
    );

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'sql_classifier.dart';
import 'sqlite_executor.dart';

/// Inspects a SQLite database.
///
/// * `SqliteAdapter(db)` — a `sqflite` / `sqflite_common_ffi` database, or a
///   Floor database via `floorDb.database`.
/// * `SqliteAdapter.executor(...)` — any other SQLite library.
///
/// Values larger than the preview budget are truncated inside SQLite (with
/// `substr`) so huge blobs never reach Dart memory during browsing.
class SqliteAdapter extends DbAdapter {
  SqliteAdapter(DatabaseExecutor database, {String type = 'sqlite'})
      : this.executor(SqfliteExecutor(database), type: type);

  SqliteAdapter.executor(this.executor, {this.type = 'sqlite'});

  final SqliteExecutor executor;

  @override
  final String type;

  static const _rowidKey = 'rowid';

  @override
  DbDataModel get dataModel => DbDataModel.relational;

  @override
  Set<DbCapability> get capabilities => const {
        DbCapability.read,
        DbCapability.filter,
        DbCapability.sort,
        DbCapability.search,
        DbCapability.insert,
        DbCapability.update,
        DbCapability.delete,
        DbCapability.clear,
        DbCapability.sql,
        DbCapability.schema,
        DbCapability.indexes,
        DbCapability.export,
      };

  // ---------------------------------------------------------------------------
  // Error mapping

  /// Runs [action], translating engine exceptions into protocol errors.
  Future<T> guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on InspectorException {
      rethrow;
    } on Exception catch (e) {
      throw mapError(e);
    }
  }

  static InspectorException mapError(Object error) {
    final message = error.toString();
    final lower = message.toLowerCase();
    if (lower.contains('database is locked') ||
        lower.contains('sqlite_busy') ||
        lower.contains('database table is locked')) {
      return InspectorException(
        ErrorCodes.databaseBusy,
        'The database is busy (locked by the application). Try again shortly.',
        {'cause': message},
      );
    }
    return InspectorException(ErrorCodes.queryFailed, message);
  }

  static String quote(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';

  // ---------------------------------------------------------------------------
  // Metadata & schema

  Future<Object?> _scalar(String sql, [List<Object?> args = const []]) async {
    final rows = await executor.select(sql, args);
    return rows.isEmpty || rows.first.isEmpty ? null : rows.first.values.first;
  }

  Future<int?> _sizeBytes() async {
    final pages = await _scalar('PRAGMA page_count');
    final pageSize = await _scalar('PRAGMA page_size');
    return pages is int && pageSize is int ? pages * pageSize : null;
  }

  @override
  Future<DatabaseMetadata> getMetadata() => guard(() async {
        return DatabaseMetadata(
          engine: 'sqlite',
          engineVersion: '${await _scalar('SELECT sqlite_version()')}',
          path: executor.path,
          sizeBytes: await _sizeBytes(),
          extra: {
            'userVersion': await _scalar('PRAGMA user_version'),
            'journalMode': await _scalar('PRAGMA journal_mode'),
            'encoding': await _scalar('PRAGMA encoding'),
            'foreignKeys': await _scalar('PRAGMA foreign_keys') == 1,
          },
        );
      });

  @override
  Future<DatabaseStats> getStats() => guard(() async {
        final overview = await getSchemaOverview();
        return DatabaseStats(
          entities: overview.entities,
          indexCount: overview.indexes.length,
          triggerCount: overview.triggers.length,
          sizeBytes: await _sizeBytes(),
        );
      });

  Future<List<Map<String, Object?>>> _master() => executor.select(
        'SELECT type, name, tbl_name, sql FROM sqlite_master '
        "WHERE name NOT LIKE 'sqlite_%' ORDER BY name",
      );

  @override
  Future<SchemaOverview> getSchemaOverview() => guard(() async {
        final master = await _master();
        final entities = <EntitySummary>[];
        final indexes = <IndexInfo>[];
        final triggers = <TriggerInfo>[];
        for (final row in master) {
          final name = row['name']! as String;
          switch (row['type']) {
            case 'table':
              entities.add(EntitySummary(
                name: name,
                kind: EntityKind.table,
                rowCount: await _scalar('SELECT COUNT(*) FROM ${quote(name)}')
                    as int?,
              ));
              indexes.addAll(await _indexes(name));
            case 'view':
              entities.add(EntitySummary(
                name: name,
                kind: EntityKind.view,
                readOnly: true,
              ));
            case 'trigger':
              triggers.add(TriggerInfo(
                name: name,
                table: row['tbl_name']! as String,
                sql: row['sql'] as String?,
              ));
          }
        }
        return SchemaOverview(
          entities: entities,
          indexes: indexes,
          triggers: triggers,
        );
      });

  Future<List<IndexInfo>> _indexes(String table) async {
    final list = await executor.select('PRAGMA index_list(${quote(table)})');
    final sqlByName = {
      for (final row in await executor.select(
        "SELECT name, sql FROM sqlite_master WHERE type = 'index' "
        'AND tbl_name = ?',
        [table],
      ))
        row['name']! as String: row['sql'] as String?,
    };
    return [
      for (final index in list)
        IndexInfo(
          name: index['name']! as String,
          table: table,
          unique: index['unique'] == 1,
          origin: index['origin'] as String?,
          partial: index['partial'] == 1,
          sql: sqlByName[index['name']],
          columns: [
            for (final c in await executor.select(
              'PRAGMA index_info(${quote(index['name']! as String)})',
            ))
              (c['name'] as String?) ?? '<expr>',
          ],
        ),
    ];
  }

  @override
  Future<TableSchema> getTableSchema(String table) => guard(() async {
        final master = await executor.select(
          'SELECT type, sql FROM sqlite_master WHERE name = ? '
          "AND type IN ('table', 'view')",
          [table],
        );
        if (master.isEmpty) throw AdapterErrors.tableNotFound(table);
        final isView = master.first['type'] == 'view';
        final sql = master.first['sql'] as String?;

        final info = await _tableInfo(table);
        final pkCount = info.where((c) => (c['pk']! as int) > 0).length;
        final columns = [
          for (final c in info)
            if (c['hidden'] != 1) _column(c, singleIntegerPk: pkCount == 1),
        ];

        final withoutRowid = sql != null &&
            RegExp(r'WITHOUT\s+ROWID', caseSensitive: false).hasMatch(sql);
        final rowKey = isView
            ? RowKeyKind.none
            : withoutRowid
                ? RowKeyKind.primaryKey
                : RowKeyKind.rowid;

        return TableSchema(
          name: table,
          kind: isView ? EntityKind.view : EntityKind.table,
          columns: columns,
          rowKey: rowKey,
          sql: sql,
          foreignKeys: isView ? const [] : await _foreignKeys(table),
          indexes: isView ? const [] : await _indexes(table),
          triggers: [
            for (final t in await executor.select(
              "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' "
              'AND tbl_name = ?',
              [table],
            ))
              TriggerInfo(
                name: t['name']! as String,
                table: table,
                sql: t['sql'] as String?,
              ),
          ],
        );
      });

  Future<List<Map<String, Object?>>> _tableInfo(String table) async {
    try {
      // table_xinfo (SQLite 3.26+) also reports generated columns.
      return await executor.select('PRAGMA table_xinfo(${quote(table)})');
    } on Exception {
      return executor.select('PRAGMA table_info(${quote(table)})');
    }
  }

  ColumnInfo _column(Map<String, Object?> c, {required bool singleIntegerPk}) {
    final declared = (c['type'] as String?) ?? '';
    final pk = c['pk']! as int;
    final hidden = c['hidden'] as int? ?? 0;
    return ColumnInfo(
      name: c['name']! as String,
      declaredType: declared,
      valueType: valueTypeForDeclared(declared),
      nullable: c['notnull'] != 1 && pk == 0,
      primaryKeyPosition: pk,
      defaultValue: c['dflt_value']?.toString(),
      // INTEGER PRIMARY KEY aliases the rowid and is assigned automatically.
      autoIncrement:
          pk == 1 && singleIntegerPk && declared.toUpperCase() == 'INTEGER',
      generated: hidden == 2 || hidden == 3,
    );
  }

  Future<List<ForeignKeyInfo>> _foreignKeys(String table) async {
    final rows = await executor.select(
      'PRAGMA foreign_key_list(${quote(table)})',
    );
    final byId = <int, List<Map<String, Object?>>>{};
    for (final row in rows) {
      byId.putIfAbsent(row['id']! as int, () => []).add(row);
    }
    return [
      for (final parts in byId.values)
        ForeignKeyInfo(
          columns: [for (final p in parts) p['from']! as String],
          referencedTable: parts.first['table']! as String,
          referencedColumns: [
            for (final p in parts) (p['to'] as String?) ?? '',
          ],
          onUpdate: parts.first['on_update'] as String? ?? 'NO ACTION',
          onDelete: parts.first['on_delete'] as String? ?? 'NO ACTION',
        ),
    ];
  }

  /// Maps a declared column type to a normalized type, following SQLite's
  /// affinity rules plus common conventions (BOOL, DATE, JSON).
  static DbValueType valueTypeForDeclared(String declared) {
    final t = declared.toUpperCase();
    if (t.isEmpty) return DbValueType.unknown;
    if (t.contains('BOOL')) return DbValueType.boolean;
    if (t.contains('DATE') || t.contains('TIME')) return DbValueType.dateTime;
    if (t.contains('JSON')) return DbValueType.json;
    if (t.contains('INT')) return DbValueType.integer;
    if (t.contains('CHAR') || t.contains('CLOB') || t.contains('TEXT')) {
      return DbValueType.text;
    }
    if (t.contains('BLOB')) return DbValueType.blob;
    if (t.contains('REAL') || t.contains('FLOA') || t.contains('DOUB')) {
      return DbValueType.real;
    }
    return DbValueType.real; // NUMERIC affinity
  }

  // ---------------------------------------------------------------------------
  // Rows

  @override
  Future<RowsPage> queryRows(RowsQuery query) => guard(() async {
        final schema = await getTableSchema(query.table);
        final where = _where(schema, query);
        final order = _orderBy(schema, query);
        final keyColumns = _keyColumns(schema);
        final limit = query.previewBytes;

        final select = <String>[
          for (var i = 0; i < keyColumns.length; i++)
            '${keyColumns[i] == _rowidKey ? _rowidKey : quote(keyColumns[i])} AS k$i',
          for (var i = 0; i < schema.columns.length; i++) ...[
            _previewExpr(quote(schema.columns[i].name), limit, 'v$i'),
            _lengthExpr(quote(schema.columns[i].name), limit, 'l$i'),
          ],
        ];
        final rows = await executor.select(
          'SELECT ${select.join(', ')} FROM ${quote(schema.name)}'
          '${where.sql}$order LIMIT ? OFFSET ?',
          [...where.args, query.pageSize, query.offset],
        );
        final total = await _scalar(
          'SELECT COUNT(*) FROM ${quote(schema.name)}${where.sql}',
          where.args,
        );

        return RowsPage(
          columns: [
            for (final c in schema.columns)
              ResultColumn(
                name: c.name,
                valueType: c.valueType,
                declaredType: c.declaredType,
              ),
          ],
          rows: [
            for (final row in rows)
              RowRecord(
                key: keyColumns.isEmpty
                    ? null
                    : {
                        for (var i = 0; i < keyColumns.length; i++)
                          keyColumns[i]: row['k$i'],
                      },
                values: [
                  for (var i = 0; i < schema.columns.length; i++)
                    _readCell(row['v$i'], row['l$i']),
                ],
              ),
          ],
          page: query.page,
          pageSize: query.pageSize,
          total: total as int?,
        );
      });

  static String _previewExpr(String column, int limit, String alias) =>
      'CASE WHEN length(CAST($column AS BLOB)) > $limit '
      'THEN substr($column, 1, $limit) ELSE $column END AS $alias';

  static String _lengthExpr(String column, int limit, String alias) =>
      'CASE WHEN length(CAST($column AS BLOB)) > $limit '
      'THEN length(CAST($column AS BLOB)) END AS $alias';

  static Object? _readCell(Object? value, Object? fullLength) {
    final v = value is List<int> && value is! Uint8List
        ? Uint8List.fromList(value)
        : value;
    if (fullLength is int && (v is String || v is Uint8List)) {
      return TruncatedValue(v!, fullLength);
    }
    return v;
  }

  @override
  Future<int> countRows(RowsQuery query) => guard(() async {
        final schema = await getTableSchema(query.table);
        final where = _where(schema, query);
        return (await _scalar(
          'SELECT COUNT(*) FROM ${quote(schema.name)}${where.sql}',
          where.args,
        ))! as int;
      });

  List<String> _keyColumns(TableSchema schema) => switch (schema.rowKey) {
        RowKeyKind.rowid => const [_rowidKey],
        RowKeyKind.primaryKey => [
            for (final c
                in (schema.columns.where((c) => c.isPrimaryKey).toList()
                  ..sort(
                      (a, b) => a.primaryKeyPosition - b.primaryKeyPosition)))
              c.name,
          ],
        _ => const [],
      };

  ColumnInfo _requireColumn(TableSchema schema, String name) =>
      schema.column(name) ??
      (throw AdapterErrors.columnNotFound(schema.name, name));

  ({String sql, List<Object?> args}) _where(
      TableSchema schema, RowsQuery query) {
    final clauses = <String>[];
    final args = <Object?>[];
    for (final f in query.filters) {
      final col = quote(_requireColumn(schema, f.column).name);
      final value = toSqlValue(f.value);
      switch (f.operator) {
        case FilterOperator.isNull:
          clauses.add('$col IS NULL');
        case FilterOperator.isNotNull:
          clauses.add('$col IS NOT NULL');
        case FilterOperator.equals:
          clauses.add(value == null ? '$col IS NULL' : '$col = ?');
          if (value != null) args.add(value);
        case FilterOperator.notEquals:
          clauses.add('$col IS NOT ?');
          args.add(value);
        case FilterOperator.contains:
          clauses.add("CAST($col AS TEXT) LIKE ? ESCAPE '\\'");
          args.add('%${_escapeLike('${f.value ?? ''}')}%');
        case FilterOperator.startsWith:
          clauses.add("CAST($col AS TEXT) LIKE ? ESCAPE '\\'");
          args.add('${_escapeLike('${f.value ?? ''}')}%');
        case FilterOperator.endsWith:
          clauses.add("CAST($col AS TEXT) LIKE ? ESCAPE '\\'");
          args.add('%${_escapeLike('${f.value ?? ''}')}');
        case FilterOperator.greaterThan:
          clauses.add('$col > ?');
          args.add(value);
        case FilterOperator.lessThan:
          clauses.add('$col < ?');
          args.add(value);
        case FilterOperator.greaterOrEqual:
          clauses.add('$col >= ?');
          args.add(value);
        case FilterOperator.lessOrEqual:
          clauses.add('$col <= ?');
          args.add(value);
      }
    }
    final search = query.search;
    if (search != null) {
      final searchable = [
        for (final c in schema.columns)
          if (c.valueType != DbValueType.blob &&
              !query.searchExcludedColumns.contains(c.name))
            c.name,
      ];
      if (searchable.isEmpty) {
        clauses.add('0');
      } else {
        clauses.add('(${[
          for (final c in searchable)
            "CAST(${quote(c)} AS TEXT) LIKE ? ESCAPE '\\'",
        ].join(' OR ')})');
        args.addAll([for (final _ in searchable) '%${_escapeLike(search)}%']);
      }
    }
    return (
      sql: clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}',
      args: args,
    );
  }

  String _orderBy(TableSchema schema, RowsQuery query) {
    final terms = [
      for (final s in query.sort)
        '${quote(_requireColumn(schema, s.column).name)} '
            '${s.direction == SortDirection.desc ? 'DESC' : 'ASC'}',
    ];
    // A unique tie-breaker keeps pagination stable.
    final keys = _keyColumns(schema);
    terms.addAll([for (final k in keys) k == _rowidKey ? _rowidKey : quote(k)]);
    return terms.isEmpty ? '' : ' ORDER BY ${terms.join(', ')}';
  }

  static String _escapeLike(String text) => text
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Converts a decoded protocol value into a SQLite-storable value.
  static Object? toSqlValue(Object? value) => switch (value) {
        bool() => value ? 1 : 0,
        DateTime() => value.toIso8601String(),
        Map() || List() => jsonEncode(value),
        _ => value,
      };

  ({String sql, List<Object?> args}) _keyWhere(TableSchema schema, RowKey key) {
    final columns = _keyColumns(schema);
    if (columns.isEmpty) {
      throw InspectorException(
        ErrorCodes.unsupportedOperation,
        '"${schema.name}" is a ${schema.kind.name}; its rows cannot be edited',
      );
    }
    for (final c in columns) {
      if (!key.containsKey(c)) {
        throw AdapterErrors.invalidKey(schema.name, 'missing "$c"');
      }
    }
    return (
      sql: ' WHERE ${[
        for (final c in columns)
          '${c == _rowidKey ? _rowidKey : quote(c)} IS ?',
      ].join(' AND ')}',
      args: [for (final c in columns) toSqlValue(key[c])],
    );
  }

  // ---------------------------------------------------------------------------
  // Writes

  @override
  Future<MutationResult> insertRow(String table, Map<String, Object?> values) =>
      guard(() async {
        final schema = await getTableSchema(table);
        if (schema.kind == EntityKind.view) {
          throw InspectorException(
            ErrorCodes.unsupportedOperation,
            'Cannot insert into view "$table"',
          );
        }
        final columns = values.keys.toList();
        for (final c in columns) {
          if (_requireColumn(schema, c).generated) {
            throw InspectorException(
              ErrorCodes.invalidRequest,
              'Column "$c" is generated and cannot be written',
            );
          }
        }
        final sql = columns.isEmpty
            ? 'INSERT INTO ${quote(table)} DEFAULT VALUES'
            : 'INSERT INTO ${quote(table)} (${columns.map(quote).join(', ')}) '
                'VALUES (${List.filled(columns.length, '?').join(', ')})';
        final id = await executor.insert(sql, [
          for (final c in columns) toSqlValue(values[c]),
        ]);
        final RowKey? insertedKey = switch (schema.rowKey) {
          RowKeyKind.rowid => {_rowidKey: id},
          RowKeyKind.primaryKey => {
              for (final c in _keyColumns(schema)) c: values[c],
            },
          _ => null,
        };
        return MutationResult(affectedRows: 1, insertedKey: insertedKey);
      });

  @override
  Future<MutationResult> updateRow(
    String table,
    RowKey key,
    Map<String, Object?> values,
  ) =>
      guard(() async {
        final schema = await getTableSchema(table);
        final where = _keyWhere(schema, key);
        final columns = values.keys.toList();
        for (final c in columns) {
          if (_requireColumn(schema, c).generated) {
            throw InspectorException(
              ErrorCodes.invalidRequest,
              'Column "$c" is generated and cannot be written',
            );
          }
        }
        final changed = await executor.modify(
          'UPDATE ${quote(table)} SET '
          '${columns.map((c) => '${quote(c)} = ?').join(', ')}${where.sql}',
          [for (final c in columns) toSqlValue(values[c]), ...where.args],
        );
        if (changed == 0) throw AdapterErrors.rowNotFound(table);
        return MutationResult(affectedRows: changed);
      });

  @override
  Future<MutationResult> deleteRow(String table, RowKey key) => guard(() async {
        final schema = await getTableSchema(table);
        final where = _keyWhere(schema, key);
        final changed = await executor.modify(
          'DELETE FROM ${quote(table)}${where.sql}',
          where.args,
        );
        if (changed == 0) throw AdapterErrors.rowNotFound(table);
        return MutationResult(affectedRows: changed);
      });

  @override
  Future<MutationResult> clearTable(String table) => guard(() async {
        final schema = await getTableSchema(table);
        if (schema.kind != EntityKind.table) {
          throw InspectorException(
            ErrorCodes.unsupportedOperation,
            'Only tables can be cleared',
          );
        }
        return MutationResult(
          affectedRows: await executor.modify('DELETE FROM ${quote(table)}'),
        );
      });

  // ---------------------------------------------------------------------------
  // SQL console

  @override
  Future<SqlResult> executeSql(SqlRequest request) => guard(() async {
        final c = SqlClassifier.classify(request.sql);
        if (c.statements.isEmpty) {
          throw InspectorException(
              ErrorCodes.invalidRequest, 'The query is empty');
        }
        if (c.statements.length > 1) {
          throw InspectorException(
            ErrorCodes.invalidRequest,
            'Run one statement at a time (found ${c.statements.length})',
          );
        }
        final sql = c.statements.single;
        final args = [for (final a in request.arguments) toSqlValue(a)];

        if (c.isRead) {
          final rows = await executor.select(
            c.isWrappable
                ? 'SELECT * FROM ($sql) LIMIT ${request.maxRows + 1}'
                : sql,
            args,
          );
          final truncated = rows.length > request.maxRows;
          final kept = truncated ? rows.sublist(0, request.maxRows) : rows;
          final names = kept.isEmpty ? <String>[] : kept.first.keys.toList();
          return SqlResult(
            kind: SqlStatementKind.read,
            columns: [
              for (final name in names)
                ResultColumn(
                  name: name,
                  valueType: DocumentAdapter.valueTypeOf(
                    kept.map((r) => r[name]).firstWhere(
                          (v) => v != null,
                          orElse: () => null,
                        ),
                  ),
                ),
            ],
            rows: [
              for (final row in kept)
                [for (final name in names) _readCell(row[name], null)],
            ],
            truncated: truncated,
          );
        }

        if (!request.allowWrite) {
          throw AdapterErrors.writeRequiresConfirmation(c.keyword);
        }
        switch (c.keyword) {
          case 'INSERT' || 'REPLACE':
            final id = await executor.insert(sql, args);
            return SqlResult(
              kind: SqlStatementKind.write,
              affectedRows: (await _scalar('SELECT changes()')) as int?,
              lastInsertId: id,
            );
          case 'UPDATE' || 'DELETE' || 'WITH':
            return SqlResult(
              kind: SqlStatementKind.write,
              affectedRows: await executor.modify(sql, args),
            );
          default:
            await executor.execute(sql, args);
            return const SqlResult(kind: SqlStatementKind.write);
        }
      });

  // ---------------------------------------------------------------------------
  // Large values

  @override
  Future<ValueChunk> readValue(ValueRef ref) => guard(() async {
        final schema = await getTableSchema(ref.table);
        final column = quote(_requireColumn(schema, ref.column).name);
        final where = _keyWhere(schema, ref.key);
        final rows = await executor.select(
          'SELECT typeof($column) AS t, length(CAST($column AS BLOB)) AS n, '
          'substr(CAST($column AS BLOB), ?, ?) AS chunk '
          'FROM ${quote(ref.table)}${where.sql}',
          [ref.offset + 1, ref.length, ...where.args],
        );
        if (rows.isEmpty) throw AdapterErrors.rowNotFound(ref.table);
        final row = rows.first;
        final chunk = row['chunk'];
        return ValueChunk(
          bytes: switch (chunk) {
            Uint8List() => chunk,
            List<int>() => Uint8List.fromList(chunk),
            String() => utf8.encode(chunk),
            _ => Uint8List(0),
          },
          offset: ref.offset,
          totalBytes: (row['n'] as int?) ?? 0,
          isText: row['t'] != 'blob',
        );
      });
}

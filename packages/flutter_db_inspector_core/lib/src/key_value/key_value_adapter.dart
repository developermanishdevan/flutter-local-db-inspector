import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

import '../adapter.dart';
import '../common/in_memory_query.dart';
import 'key_value_store.dart';

/// Generic adapter for key/value engines (Hive boxes, SharedPreferences,
/// secure storage).
///
/// Every store is presented as an entity of kind [EntityKind.box] with three
/// columns: `key`, `value` and `type` (the runtime type of the value). Rows
/// are addressed by `{"key": <key>}`.
class KeyValueAdapter extends DbAdapter {
  KeyValueAdapter({
    required this.type,
    required Iterable<KeyValueStore> Function() stores,
    this.engine,
    this.engineVersion,
  }) : _stores = stores;

  @override
  final String type;

  /// Engine name for metadata; defaults to [type].
  final String? engine;
  final String? engineVersion;

  final Iterable<KeyValueStore> Function() _stores;

  static const keyColumn = 'key';
  static const valueColumn = 'value';
  static const typeColumn = 'type';

  @override
  DbDataModel get dataModel => DbDataModel.keyValue;

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
        DbCapability.schema,
        DbCapability.export,
      };

  KeyValueStore _store(String name) {
    for (final store in _stores()) {
      if (store.name == name) return store;
    }
    throw AdapterErrors.tableNotFound(name);
  }

  @override
  Future<DatabaseMetadata> getMetadata() async => DatabaseMetadata(
        engine: engine ?? type,
        engineVersion: engineVersion,
        extra: {'stores': _stores().length},
      );

  @override
  Future<SchemaOverview> getSchemaOverview() async => SchemaOverview(
        entities: [
          for (final s in _stores())
            EntitySummary(
              name: s.name,
              kind: EntityKind.box,
              rowCount: s.length,
              readOnly: !s.writable,
            ),
        ]..sort((a, b) => a.name.compareTo(b.name)),
      );

  @override
  Future<TableSchema> getTableSchema(String table) async {
    final store = _store(table);
    return TableSchema(
      name: store.name,
      kind: EntityKind.box,
      rowKey: store.writable ? RowKeyKind.key : RowKeyKind.none,
      columns: const [
        ColumnInfo(
          name: keyColumn,
          valueType: DbValueType.unknown,
          declaredType: 'key',
          nullable: false,
          primaryKeyPosition: 1,
        ),
        ColumnInfo(name: valueColumn, valueType: DbValueType.json),
        ColumnInfo(
          name: typeColumn,
          valueType: DbValueType.text,
          generated: true,
        ),
      ],
    );
  }

  static const _columns = [
    ResultColumn(name: keyColumn),
    ResultColumn(name: valueColumn, valueType: DbValueType.json),
    ResultColumn(name: typeColumn, valueType: DbValueType.text),
  ];

  @override
  Future<RowsPage> queryRows(RowsQuery query) async {
    final store = _store(query.table);
    _validateColumns(query);
    final writable = store.writable;

    RowRecord record(Object key, Object? value) => RowRecord(
          key: writable ? {keyColumn: key} : null,
          values: [
            key,
            InMemoryQuery.displayValue(value),
            InMemoryQuery.typeName(value)
          ],
        );

    // Fast path: plain paging touches only the requested keys.
    if (query.filters.isEmpty && query.search == null && query.sort.isEmpty) {
      final keys = store.keys.skip(query.offset).take(query.pageSize);
      return RowsPage(
        columns: _columns,
        rows: [for (final k in keys) record(k, await store.get(k))],
        page: query.page,
        pageSize: query.pageSize,
        total: store.length,
      );
    }

    final matches = await _matching(store, query);
    if (query.sort.isNotEmpty) {
      matches.sort(
        InMemoryQuery.comparator<_Entry>(query.sort, (e, c) => e.column(c)),
      );
    }
    return RowsPage(
      columns: _columns,
      rows: [
        for (final e in matches.skip(query.offset).take(query.pageSize))
          record(e.key, e.value),
      ],
      page: query.page,
      pageSize: query.pageSize,
      total: matches.length,
    );
  }

  @override
  Future<int> countRows(RowsQuery query) async {
    final store = _store(query.table);
    _validateColumns(query);
    if (query.filters.isEmpty && query.search == null) return store.length;
    return (await _matching(store, query)).length;
  }

  @override
  Future<MutationResult> insertRow(
      String table, Map<String, Object?> values) async {
    final store = _writable(table);
    final key = _parseKey(table, values[keyColumn]);
    if (store.containsKey(key)) {
      throw InspectorException(
        ErrorCodes.invalidRequest,
        'Key "$key" already exists in "$table"',
      );
    }
    await store.put(key, store.decodeForWrite(values[valueColumn]));
    return MutationResult(affectedRows: 1, insertedKey: {keyColumn: key});
  }

  @override
  Future<MutationResult> updateRow(
    String table,
    RowKey key,
    Map<String, Object?> values,
  ) async {
    final store = _writable(table);
    final k = _parseKey(table, key[keyColumn]);
    if (!store.containsKey(k)) throw AdapterErrors.rowNotFound(table);
    for (final column in values.keys) {
      if (column != valueColumn) {
        throw InspectorException(
          ErrorCodes.unsupportedOperation,
          'Only the "$valueColumn" column can be edited in key/value stores',
        );
      }
    }
    final previous = await store.get(k);
    await store.put(
        k, store.decodeForWrite(values[valueColumn], previous: previous));
    return const MutationResult(affectedRows: 1);
  }

  @override
  Future<MutationResult> deleteRow(String table, RowKey key) async {
    final store = _writable(table);
    final k = _parseKey(table, key[keyColumn]);
    if (!store.containsKey(k)) throw AdapterErrors.rowNotFound(table);
    await store.delete(k);
    return const MutationResult(affectedRows: 1);
  }

  @override
  Future<MutationResult> clearTable(String table) async =>
      MutationResult(affectedRows: await _writable(table).clear());

  @override
  Future<ValueChunk> readValue(ValueRef ref) async {
    final store = _store(ref.table);
    final key = _parseKey(ref.table, ref.key[keyColumn]);
    if (!store.containsKey(key)) throw AdapterErrors.rowNotFound(ref.table);
    final value = await store.get(key);
    final Uint8List bytes;
    final bool isText;
    switch (ref.column) {
      case keyColumn:
        bytes = utf8.encode('$key');
        isText = true;
      case valueColumn when value is MaskedValue:
        // Stores mask secrets (e.g. secure storage); never read them out.
        throw InspectorException(
          ErrorCodes.permissionDenied,
          'The value of "$key" in "${ref.table}" is masked',
          {'table': ref.table, 'column': ref.column},
        );
      case valueColumn when value is Uint8List:
        bytes = value;
        isText = false;
      case valueColumn:
        final display = InMemoryQuery.displayValue(value);
        bytes = utf8.encode(display is String ? display : jsonEncode(display));
        isText = true;
      default:
        throw AdapterErrors.columnNotFound(ref.table, ref.column);
    }
    final start = ref.offset.clamp(0, bytes.length);
    final end = (start + ref.length).clamp(start, bytes.length);
    return ValueChunk(
      bytes: Uint8List.sublistView(bytes, start, end),
      offset: start,
      totalBytes: bytes.length,
      isText: isText,
    );
  }

  // ---------------------------------------------------------------------------

  KeyValueStore _writable(String table) {
    final store = _store(table);
    if (!store.writable) {
      throw InspectorException(
        ErrorCodes.writeNotAllowed,
        'Store "$table" is read-only',
        const {'requiresConfirmation': false},
      );
    }
    return store;
  }

  Object _parseKey(String table, Object? key) {
    if (key is int || key is String) return key!;
    throw AdapterErrors.invalidKey(table, 'keys must be integers or strings');
  }

  void _validateColumns(RowsQuery query) {
    for (final column in [
      ...query.filters.map((f) => f.column),
      ...query.sort.map((s) => s.column),
    ]) {
      if (column != keyColumn &&
          column != valueColumn &&
          column != typeColumn) {
        throw AdapterErrors.columnNotFound(query.table, column);
      }
    }
  }

  Future<List<_Entry>> _matching(KeyValueStore store, RowsQuery query) async {
    final result = <_Entry>[];
    for (final key in store.keys) {
      final entry = _Entry(key, await store.get(key));
      if (InMemoryQuery.matches(
          query, const [keyColumn, valueColumn], entry.column)) {
        result.add(entry);
      }
    }
    return result;
  }
}

final class _Entry {
  _Entry(this.key, this.value);

  final Object key;
  final Object? value;

  Object? column(String name) => switch (name) {
        KeyValueAdapter.keyColumn => key,
        KeyValueAdapter.typeColumn => InMemoryQuery.typeName(value),
        _ => InMemoryQuery.displayValue(value),
      };
}

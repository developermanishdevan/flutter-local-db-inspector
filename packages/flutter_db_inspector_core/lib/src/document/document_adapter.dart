import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

import '../adapter.dart';
import '../common/in_memory_query.dart';
import 'document_collection.dart';

/// Generic adapter for object/document engines.
///
/// Collections are entities of kind [EntityKind.collection]; documents become
/// rows whose columns are the declared (or inferred) fields. Rows are
/// addressed by `{<idField>: id}`.
class DocumentAdapter extends DbAdapter {
  DocumentAdapter({
    required this.type,
    required Iterable<DocumentCollection> Function() collections,
    this.engine,
    this.engineVersion,
    this.maxScanDocuments = 200000,
  }) : _collections = collections;

  @override
  final String type;
  final String? engine;
  final String? engineVersion;

  /// Upper bound for in-memory filtering when a collection has no native
  /// query support; larger scans fail with `RESULT_TOO_LARGE` instead of
  /// stalling the app.
  final int maxScanDocuments;

  final Iterable<DocumentCollection> Function() _collections;

  static const _scanBatch = 500;
  static const _inferSample = 50;

  @override
  DbDataModel get dataModel => DbDataModel.document;

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
        DbCapability.indexes,
        DbCapability.export,
      };

  DocumentCollection _collection(String name) {
    for (final c in _collections()) {
      if (c.name == name) return c;
    }
    throw AdapterErrors.tableNotFound(name);
  }

  @override
  Future<DatabaseMetadata> getMetadata() async => DatabaseMetadata(
        engine: engine ?? type,
        engineVersion: engineVersion,
        extra: {'collections': _collections().length},
      );

  @override
  Future<SchemaOverview> getSchemaOverview() async {
    final collections = _collections().toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return SchemaOverview(
      entities: [
        for (final c in collections)
          EntitySummary(
            name: c.name,
            kind: EntityKind.collection,
            rowCount: await c.count(),
            readOnly: !c.writable,
          ),
      ],
      indexes: [for (final c in collections) ...c.indexes],
    );
  }

  @override
  Future<TableSchema> getTableSchema(String table) async {
    final c = _collection(table);
    return TableSchema(
      name: c.name,
      kind: EntityKind.collection,
      rowKey: c.writable ? RowKeyKind.key : RowKeyKind.none,
      columns: await _columns(c),
      indexes: c.indexes,
    );
  }

  Future<List<ColumnInfo>> _columns(DocumentCollection c) async {
    final declared = c.fields;
    final sample = await c.list(offset: 0, limit: _inferSample);
    // String ids (Sembast string stores, UUIDs, ...) are not auto-assigned.
    final idType = sample.isEmpty
        ? DbValueType.integer
        : valueTypeOf(sample.first[c.idField]);
    final columns = <ColumnInfo>[
      if (!declared.any((f) => f.name == c.idField))
        ColumnInfo(
          name: c.idField,
          valueType: idType,
          nullable: false,
          primaryKeyPosition: 1,
          autoIncrement: idType == DbValueType.integer,
        ),
      ...declared,
    ];
    if (declared.isNotEmpty) return columns;
    // Schemaless: infer from a sample of stored documents.
    final known = {for (final col in columns) col.name};
    for (final doc in sample) {
      for (final entry in doc.entries) {
        if (known.add(entry.key)) {
          columns.add(ColumnInfo(
            name: entry.key,
            valueType: valueTypeOf(entry.value),
          ));
        }
      }
    }
    return columns;
  }

  /// Best-effort normalized type of a runtime value.
  static DbValueType valueTypeOf(Object? value) => switch (value) {
        null => DbValueType.nullValue,
        bool() => DbValueType.boolean,
        int() => DbValueType.integer,
        double() => DbValueType.real,
        String() => DbValueType.text,
        Uint8List() => DbValueType.blob,
        DateTime() => DbValueType.dateTime,
        Map() || List() => DbValueType.json,
        _ => DbValueType.unknown,
      };

  @override
  Future<RowsPage> queryRows(RowsQuery query) async {
    final c = _collection(query.table);
    final schema = await _columns(c);
    _validate(query, schema);

    final List<Map<String, Object?>> docs;
    final int total;
    if (query.filters.isEmpty && query.search == null && query.sort.isEmpty) {
      docs = await c.list(offset: query.offset, limit: query.pageSize);
      total = await c.count();
    } else {
      final page = await c.query(query) ?? await _scan(c, query, schema);
      docs = page.documents;
      total = page.total;
    }

    // Schemaless documents may carry fields the sample did not show.
    final columns = [...schema];
    final known = {for (final col in columns) col.name};
    for (final doc in docs) {
      for (final entry in doc.entries) {
        if (known.add(entry.key)) {
          columns.add(ColumnInfo(
            name: entry.key,
            valueType: valueTypeOf(entry.value),
          ));
        }
      }
    }

    return RowsPage(
      columns: [
        for (final col in columns)
          ResultColumn(
            name: col.name,
            valueType: col.valueType,
            declaredType: col.declaredType.isEmpty ? null : col.declaredType,
          ),
      ],
      rows: [
        for (final doc in docs)
          RowRecord(
            key: c.writable ? {c.idField: doc[c.idField]} : null,
            values: [
              for (final col in columns)
                InMemoryQuery.displayValue(doc[col.name]),
            ],
          ),
      ],
      page: query.page,
      pageSize: query.pageSize,
      total: total,
    );
  }

  @override
  Future<int> countRows(RowsQuery query) async {
    final c = _collection(query.table);
    if (query.filters.isEmpty && query.search == null) return c.count();
    _validate(query, await _columns(c));
    final page = await c.query(query.copyWith(page: 0, pageSize: 1)) ??
        await _scan(c, query.copyWith(page: 0, pageSize: 1), await _columns(c));
    return page.total;
  }

  void _validate(RowsQuery query, List<ColumnInfo> columns) {
    final names = {for (final c in columns) c.name};
    for (final column in [
      ...query.filters.map((f) => f.column),
      ...query.sort.map((s) => s.column),
    ]) {
      // Schemaless collections may filter on fields outside the sample.
      if (!names.contains(column) &&
          columns.any((c) => c.declaredType.isNotEmpty)) {
        throw AdapterErrors.columnNotFound(query.table, column);
      }
    }
  }

  Future<DocumentPage> _scan(
    DocumentCollection c,
    RowsQuery query,
    List<ColumnInfo> columns,
  ) async {
    final count = await c.count();
    if (count > maxScanDocuments) {
      throw InspectorException(
        ErrorCodes.resultTooLarge,
        'Filtering "${c.name}" needs a scan of $count documents, above the '
        'limit of $maxScanDocuments for collections without native queries.',
        {'documents': count, 'maxScanDocuments': maxScanDocuments},
      );
    }
    final searchable = [for (final col in columns) col.name];
    final matches = <Map<String, Object?>>[];
    for (var offset = 0; offset < count; offset += _scanBatch) {
      final batch = await c.list(offset: offset, limit: _scanBatch);
      for (final doc in batch) {
        if (InMemoryQuery.matches(
          query,
          searchable,
          (name) => InMemoryQuery.displayValue(doc[name]),
        )) {
          matches.add(doc);
        }
      }
      if (batch.length < _scanBatch) break;
    }
    if (query.sort.isNotEmpty) {
      matches.sort(InMemoryQuery.comparator<Map<String, Object?>>(
        query.sort,
        (doc, name) => InMemoryQuery.displayValue(doc[name]),
      ));
    }
    return DocumentPage(
      documents: matches.skip(query.offset).take(query.pageSize).toList(),
      total: matches.length,
    );
  }

  // ---------------------------------------------------------------------------
  // Writes

  DocumentCollection _writable(String table) {
    final c = _collection(table);
    if (!c.writable) {
      throw InspectorException(
        ErrorCodes.writeNotAllowed,
        'Collection "$table" is read-only',
        const {'requiresConfirmation': false},
      );
    }
    return c;
  }

  Object _id(DocumentCollection c, RowKey key) {
    final id = key[c.idField];
    if (id is int || id is String) return id!;
    throw AdapterErrors.invalidKey(c.name, 'expected "${c.idField}"');
  }

  @override
  Future<MutationResult> insertRow(
      String table, Map<String, Object?> values) async {
    final c = _writable(table);
    final id = await c.insert(values);
    return MutationResult(affectedRows: 1, insertedKey: {c.idField: id});
  }

  @override
  Future<MutationResult> updateRow(
    String table,
    RowKey key,
    Map<String, Object?> values,
  ) async {
    final c = _writable(table);
    if (values.containsKey(c.idField)) {
      throw InspectorException(
        ErrorCodes.unsupportedOperation,
        'The id field "${c.idField}" cannot be changed',
      );
    }
    if (!await c.update(_id(c, key), values)) {
      throw AdapterErrors.rowNotFound(table);
    }
    return const MutationResult(affectedRows: 1);
  }

  @override
  Future<MutationResult> deleteRow(String table, RowKey key) async {
    final c = _writable(table);
    if (!await c.delete(_id(c, key))) throw AdapterErrors.rowNotFound(table);
    return const MutationResult(affectedRows: 1);
  }

  @override
  Future<MutationResult> clearTable(String table) async =>
      MutationResult(affectedRows: await _writable(table).clear());

  @override
  Future<ValueChunk> readValue(ValueRef ref) async {
    final c = _collection(ref.table);
    final doc = await c.get(_id(c, ref.key));
    if (doc == null) throw AdapterErrors.rowNotFound(ref.table);
    final value = InMemoryQuery.displayValue(doc[ref.column]);
    final bytes = switch (value) {
      Uint8List() => value,
      String() => utf8.encode(value),
      _ => utf8.encode(jsonEncode(DbValueCodec.encode(value))),
    };
    final start = ref.offset.clamp(0, bytes.length);
    final end = (start + ref.length).clamp(start, bytes.length);
    return ValueChunk(
      bytes: Uint8List.sublistView(bytes, start, end),
      offset: start,
      totalBytes: bytes.length,
      isText: value is! Uint8List,
    );
  }
}

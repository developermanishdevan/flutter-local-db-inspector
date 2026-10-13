import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import '../json.dart';
import '../value.dart';

/// Raw (decoded) column → value map identifying one row, e.g.
/// `{"rowid": 42}` or `{"tenant": "a", "id": 7}`.
typedef RowKey = Map<String, Object?>;

JsonMap encodeKey(RowKey key) =>
    {for (final e in key.entries) e.key: DbValueCodec.encode(e.value)};

RowKey decodeKey(JsonMap json) =>
    {for (final e in json.entries) e.key: DbValueCodec.decode(e.value)};

Map<String, Object?> decodeValues(JsonMap json) => decodeKey(json);

enum FilterOperator {
  equals,
  notEquals,
  contains,
  startsWith,
  endsWith,
  greaterThan,
  lessThan,
  greaterOrEqual,
  lessOrEqual,
  isNull,
  isNotNull;

  /// Whether the operator takes no value.
  bool get isUnary => this == isNull || this == isNotNull;

  static FilterOperator fromWire(String name) => values.firstWhere(
        (o) => o.name == name,
        orElse: () => throw InspectorException(
          ErrorCodes.invalidRequest,
          'Unknown filter operator "$name"',
        ),
      );
}

final class RowFilter {
  const RowFilter({required this.column, required this.operator, this.value});

  factory RowFilter.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return RowFilter(
      column: r.string('column'),
      operator: FilterOperator.fromWire(r.string('operator')),
      value: DbValueCodec.decode(json['value']),
    );
  }

  final String column;
  final FilterOperator operator;
  final Object? value;

  JsonMap toJson() => {
        'column': column,
        'operator': operator.name,
        if (!operator.isUnary) 'value': DbValueCodec.encode(value),
      };
}

enum SortDirection {
  asc,
  desc;

  static SortDirection fromWire(String? name) => switch (name) {
        'desc' || 'descending' => desc,
        _ => asc,
      };
}

final class RowSort {
  const RowSort({required this.column, this.direction = SortDirection.asc});

  factory RowSort.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return RowSort(
      column: r.string('column'),
      direction: SortDirection.fromWire(r.optString('direction')),
    );
  }

  final String column;
  final SortDirection direction;

  JsonMap toJson() => {'column': column, 'direction': direction.name};
}

/// Parameters of `rows.query` (and, without paging, `rows.count`).
final class RowsQuery {
  const RowsQuery({
    required this.table,
    this.page = 0,
    this.pageSize = 50,
    this.filters = const [],
    this.sort = const [],
    this.search,
    this.previewBytes = 10 * 1024,
    this.searchExcludedColumns = const {},
  });

  factory RowsQuery.fromJson(JsonMap json) {
    final r = JsonReader(json);
    final search = r.optString('search')?.trim();
    return RowsQuery(
      table: r.string('table'),
      page: r.optInt('page') ?? 0,
      pageSize: r.optInt('pageSize') ?? 50,
      filters: r.objects('filters', RowFilter.fromJson),
      sort: r.objects('sort', RowSort.fromJson),
      search: (search == null || search.isEmpty) ? null : search,
    );
  }

  final String table;
  final int page;
  final int pageSize;
  final List<RowFilter> filters;
  final List<RowSort> sort;

  /// Free-text search across all text-like columns.
  final String? search;

  /// Adapters should avoid reading more than this many bytes of a single
  /// value. Set by the runtime, not by clients.
  final int previewBytes;

  /// Columns adapters must leave out of [search] (sensitive columns). Set by
  /// the runtime, not by clients.
  final Set<String> searchExcludedColumns;

  int get offset => page * pageSize;

  RowsQuery copyWith({
    int? page,
    int? pageSize,
    int? previewBytes,
    Set<String>? searchExcludedColumns,
  }) =>
      RowsQuery(
        table: table,
        page: page ?? this.page,
        pageSize: pageSize ?? this.pageSize,
        filters: filters,
        sort: sort,
        search: search,
        previewBytes: previewBytes ?? this.previewBytes,
        searchExcludedColumns:
            searchExcludedColumns ?? this.searchExcludedColumns,
      );

  JsonMap toJson() => {
        'table': table,
        'page': page,
        'pageSize': pageSize,
        'filters': [for (final f in filters) f.toJson()],
        'sort': [for (final s in sort) s.toJson()],
        if (search != null) 'search': search,
      };
}

/// A column in a result set.
final class ResultColumn {
  const ResultColumn({
    required this.name,
    this.valueType = DbValueType.unknown,
    this.declaredType,
  });

  factory ResultColumn.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return ResultColumn(
      name: r.string('name'),
      valueType: DbValueType.fromWire(r.optString('valueType')),
      declaredType: r.optString('declaredType'),
    );
  }

  final String name;
  final DbValueType valueType;
  final String? declaredType;

  JsonMap toJson() => {
        'name': name,
        'valueType': valueType.wireName,
        if (declaredType != null) 'declaredType': declaredType,
      };
}

/// One row: raw values in column order plus the key used for edits.
final class RowRecord {
  const RowRecord({required this.values, this.key});

  /// `null` when the row cannot be addressed (read-only).
  final RowKey? key;
  final List<Object?> values;

  JsonMap toJson(ValueEncodingOptions options) => {
        'key': key == null ? null : encodeKey(key!),
        'values': [for (final v in values) DbValueCodec.encode(v, options)],
      };
}

/// Result of `rows.query`.
final class RowsPage {
  const RowsPage({
    required this.columns,
    required this.rows,
    required this.page,
    required this.pageSize,
    this.total,
  });

  final List<ResultColumn> columns;
  final List<RowRecord> rows;
  final int page;
  final int pageSize;

  /// Total number of matching rows, when known.
  final int? total;

  JsonMap toJson(
          [ValueEncodingOptions options = const ValueEncodingOptions()]) =>
      {
        'columns': [for (final c in columns) c.toJson()],
        'rows': [for (final r in rows) r.toJson(options)],
        'page': page,
        'pageSize': pageSize,
        if (total != null) 'total': total,
      };
}

final class MutationResult {
  const MutationResult({required this.affectedRows, this.insertedKey});

  final int affectedRows;

  /// Key of an inserted row, when the engine reports one.
  final RowKey? insertedKey;

  JsonMap toJson() => {
        'affectedRows': affectedRows,
        if (insertedKey != null) 'insertedKey': encodeKey(insertedKey!),
      };
}

/// Addresses one value for chunked reads (`value.read`).
final class ValueRef {
  const ValueRef({
    required this.table,
    required this.key,
    required this.column,
    this.offset = 0,
    this.length = 1024 * 1024,
  });

  factory ValueRef.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return ValueRef(
      table: r.string('table'),
      key: decodeKey(r.map('key')),
      column: r.string('column'),
      offset: r.optInt('offset') ?? 0,
      length: r.optInt('length') ?? 1024 * 1024,
    );
  }

  final String table;
  final RowKey key;
  final String column;
  final int offset;
  final int length;

  ValueRef withLength(int length) => ValueRef(
        table: table,
        key: key,
        column: column,
        offset: offset,
        length: length,
      );
}

/// A slice of a large value. Text is returned as UTF-8 bytes so slices can be
/// concatenated byte-exactly by the client.
final class ValueChunk {
  const ValueChunk({
    required this.bytes,
    required this.offset,
    required this.totalBytes,
    required this.isText,
  });

  final Uint8List bytes;
  final int offset;
  final int totalBytes;
  final bool isText;

  bool get done => offset + bytes.length >= totalBytes;

  JsonMap toJson() => {
        'base64': base64Encode(bytes),
        'offset': offset,
        'length': bytes.length,
        'totalBytes': totalBytes,
        'isText': isText,
        'done': done,
      };
}

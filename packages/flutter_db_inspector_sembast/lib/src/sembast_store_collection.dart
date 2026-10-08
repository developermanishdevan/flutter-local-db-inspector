import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:sembast/sembast.dart';

import 'sembast_values.dart';

/// One Sembast store exposed as a [DocumentCollection].
///
/// * Rows are addressed by the record key under [idField] (`_key`, Sembast's
///   own [Field.key] name). Keys may be `int` or `String`.
/// * Map records show their fields as columns. Records whose value is not a
///   map (a string, number, list, ...) are shown as a single [valueField]
///   column (`_value`, Sembast's [Field.value] name), so stores written with
///   `StoreRef<int, String>` and the like stay browsable and editable.
/// * Sembast [Timestamp]s and [Blob]s are shown as date-times and bytes.
final class SembastStoreCollection extends DocumentCollection {
  SembastStoreCollection(this._db, this.name);

  final Database _db;

  @override
  final String name;

  /// Column holding the record key.
  static final String keyField = Field.key;

  /// Column holding the value of records that are not maps.
  static final String valueField = Field.value;

  @override
  String get idField => keyField;

  /// Untyped view of the store: keys can be `int` or `String` and values any
  /// Sembast value, whatever typed `StoreRef` the application uses.
  StoreRef<Object, Object?> get _store => StoreRef<Object, Object?>(name);

  @override
  Future<int> count() => _store.count(_db);

  @override
  Future<List<Map<String, Object?>>> list({
    required int offset,
    required int limit,
  }) async {
    final records = await _store.find(
      _db,
      finder: Finder(
        sortOrders: [SortOrder<Object?>(Field.key)],
        offset: offset,
        limit: limit,
      ),
    );
    return [for (final r in records) _document(r.key, r.value)];
  }

  @override
  Future<Map<String, Object?>?> get(Object id) async {
    final value = await _store.record(id).get(_db);
    return value == null ? null : _document(id, value);
  }

  @override
  Future<Object> insert(Map<String, Object?> document) {
    final fields = {...document};
    final key = fields.remove(keyField);
    final value = _storedValue(fields);
    return _db.transaction((txn) async {
      if (key != null) {
        if (key is! int && key is! String) {
          throw InspectorException(
            ErrorCodes.invalidRequest,
            'Sembast keys must be int or String, got ${key.runtimeType}',
          );
        }
        final added = await _store.record(key).add(txn, value);
        if (added == null) {
          throw InspectorException(
            ErrorCodes.invalidRequest,
            'A record with key $key already exists in "$name"',
            {'table': name},
          );
        }
        return key;
      }
      // Generate a key of the same type as the existing ones (int for an
      // empty store), as the application's typed StoreRef would.
      final existing = await _store.findKey(txn);
      if (existing is String) {
        return StoreRef<String, Object?>(name).add(txn, value);
      }
      return StoreRef<int, Object?>(name).add(txn, value);
    });
  }

  @override
  Future<bool> update(Object id, Map<String, Object?> changes) =>
      _db.transaction((txn) async {
        final record = _store.record(id);
        final current = await record.get(txn);
        if (current == null) return false;
        final Object? next;
        if (current is Map) {
          if (changes.containsKey(valueField)) {
            throw InspectorException(
              ErrorCodes.invalidRequest,
              'Record $id of "$name" is a map; edit its fields instead of '
              '"$valueField"',
            );
          }
          next = {
            ...current.cast<String, Object?>(),
            for (final e in changes.entries)
              e.key: SembastValues.write(e.value),
          };
        } else {
          if (changes.keys.any((k) => k != valueField)) {
            throw InspectorException(
              ErrorCodes.invalidRequest,
              'Record $id of "$name" is not a map; only "$valueField" can be '
              'edited',
            );
          }
          next = _storedValue(changes);
        }
        await record.put(txn, next);
        return true;
      });

  @override
  Future<bool> delete(Object id) async =>
      await _store.record(id).delete(_db) != null;

  @override
  Future<int> clear() => _store.delete(_db);

  // ---------------------------------------------------------------------------
  // Native query

  /// Filters and sorts with a Sembast [Finder] (paging and counting happen
  /// inside Sembast). Free-text search returns `null` so that the generic
  /// engine evaluates it, honouring masked columns.
  ///
  /// The inspector sends loosely typed values (a number typed in the UI may
  /// arrive as text), so comparison operators use [Filter.custom] with the
  /// runtime's coercion rules, while null checks and text matching map to
  /// Sembast's own [Filter.isNull], [Filter.notNull] and
  /// [Filter.matchesRegExp].
  @override
  Future<DocumentPage?> query(RowsQuery query) async {
    if (query.search != null) return null;
    // `_value` means "the record when it is not a map"; Sembast resolves it
    // to the whole record, so such queries run in memory instead.
    if ([
      ...query.filters.map((f) => f.column),
      ...query.sort.map((s) => s.column),
    ].contains(valueField)) {
      return null;
    }

    final filter = query.filters.isEmpty
        ? null
        : Filter.and([for (final f in query.filters) _filter(f)]);
    final records = await _store.find(
      _db,
      finder: Finder(
        filter: filter,
        sortOrders: [
          for (final s in query.sort)
            SortOrder<Object?>.custom(
              _field(s.column),
              (a, b) => InMemoryQuery.compareValues(
                SembastValues.read(a),
                SembastValues.read(b),
              ),
              s.direction == SortDirection.asc,
            ),
          // Stable paging between equal sort values.
          SortOrder<Object?>(Field.key),
        ],
        offset: query.offset,
        limit: query.pageSize,
      ),
    );
    return DocumentPage(
      documents: [for (final r in records) _document(r.key, r.value)],
      total: await _store.count(_db, filter: filter),
    );
  }

  Filter _filter(RowFilter f) {
    final field = _field(f.column);
    bool loose(RecordSnapshot<Object?, Object?> record) =>
        InMemoryQuery.matchesFilter(_column(record, f.column), f);

    switch (f.operator) {
      case FilterOperator.isNull:
        return Filter.isNull(field);
      case FilterOperator.isNotNull:
        return Filter.notNull(field);
      case FilterOperator.contains ||
            FilterOperator.startsWith ||
            FilterOperator.endsWith:
        final text = RegExp.escape(InMemoryQuery.searchText(f.value));
        final pattern = switch (f.operator) {
          FilterOperator.startsWith => '^$text',
          FilterOperator.endsWith => '$text\$',
          _ => text,
        };
        return Filter.or([
          Filter.matchesRegExp(field, RegExp(pattern, caseSensitive: false)),
          // Numbers, dates, maps and lists match on their text form.
          Filter.custom((r) => _column(r, f.column) is! String && loose(r)),
        ]);
      case FilterOperator.equals ||
            FilterOperator.notEquals ||
            FilterOperator.greaterThan ||
            FilterOperator.lessThan ||
            FilterOperator.greaterOrEqual ||
            FilterOperator.lessOrEqual:
        return Filter.custom(loose);
    }
  }

  /// Sembast field path of a column (dots in field names are literal).
  String _field(String column) =>
      column == keyField ? Field.key : FieldKey.escape(column);

  /// Value of [column] in a record, as the generic engine displays it.
  Object? _column(RecordSnapshot<Object?, Object?> record, String column) {
    if (column == keyField) return record.key;
    final value = record.value;
    return value is Map ? SembastValues.read(value[column]) : null;
  }

  // ---------------------------------------------------------------------------

  Map<String, Object?> _document(Object? key, Object? value) {
    final read = SembastValues.read(value);
    return {
      keyField: key,
      if (read is Map<String, Object?>) ...read else valueField: read,
    };
  }

  /// The Sembast value for an inserted/edited document: a lone [valueField]
  /// stores a scalar record, anything else a map record.
  Object _storedValue(Map<String, Object?> fields) {
    if (fields.length == 1 && fields.containsKey(valueField)) {
      final value = SembastValues.write(fields[valueField]);
      if (value == null) {
        throw InspectorException(
          ErrorCodes.invalidRequest,
          'Sembast records cannot be null',
        );
      }
      return value;
    }
    if (fields.containsKey(valueField)) {
      throw InspectorException(
        ErrorCodes.invalidRequest,
        '"$valueField" holds non-map records and cannot be combined with '
        'other fields',
      );
    }
    return SembastValues.write(fields)!;
  }
}

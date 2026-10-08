import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:isar_community/isar.dart';

import 'isar_values.dart';

/// One Isar collection exposed as a [DocumentCollection], without
/// per-collection code.
///
/// Objects are read with `exportJson` and written with `importJson`, so the
/// binding works from the [CollectionSchema] alone: properties become columns,
/// embedded objects and lists are JSON, the `Id` property is the row key.
/// Filters, sorting, paging and counting run as native Isar queries when they
/// map onto Isar's typed conditions; anything else (free-text search, filters
/// on lists, embedded objects, floating point equality, ...) returns `null`
/// from [query] so the generic engine evaluates it in memory.
final class IsarCollectionBinding extends DocumentCollection {
  IsarCollectionBinding(this.isar, this.schema)
      : _collection = _resolve(isar, schema),
        _values = IsarValues(schema);

  final Isar isar;
  final CollectionSchema<Object?> schema;
  final IsarCollection<Object?> _collection;
  final IsarValues _values;

  static IsarCollection<Object?> _resolve(
    Isar isar,
    CollectionSchema<Object?> schema,
  ) {
    late IsarCollection<Object?> collection;
    // Recovers the schema's object type so the typed (public) accessor can be
    // used; Isar offers no public untyped lookup.
    schema.toCollection(<T>() => collection = isar.collection<T>());
    return collection;
  }

  @override
  String get name => schema.name;

  @override
  String get idField => schema.idName;

  @override
  List<ColumnInfo> get fields => [
        ColumnInfo(
          name: schema.idName,
          valueType: DbValueType.integer,
          declaredType: 'Id',
          nullable: false,
          primaryKeyPosition: 1,
          autoIncrement: true,
        ),
        for (final p in schema.properties.values)
          ColumnInfo(
            name: p.name,
            valueType: IsarValues.valueType(p.type),
            declaredType: _declaredType(p),
          ),
      ];

  static String _declaredType(PropertySchema p) {
    final type = switch (p.target) {
      final String target => '${p.type.schemaName}<$target>',
      null => p.type.schemaName,
    };
    final enumMap = p.enumMap;
    if (enumMap == null) return type;
    return '$type enum(${[
      for (final e in enumMap.entries) '${e.key}=${e.value}',
    ].join(', ')})';
  }

  @override
  List<IndexInfo> get indexes => [
        for (final index in schema.indexes.values)
          IndexInfo(
            name: index.name,
            table: schema.name,
            columns: [for (final p in index.properties) p.name],
            unique: index.unique,
            origin: index.unique ? 'u' : 'c',
          ),
      ];

  @override
  Future<int> count() => _collection.count();

  @override
  Future<List<Map<String, Object?>>> list({
    required int offset,
    required int limit,
  }) =>
      _export(_buildQuery(offset: offset, limit: limit));

  @override
  Future<Map<String, Object?>?> get(Object id) async {
    final raw = await _raw(_intId(id));
    return raw == null ? null : _values.read(raw);
  }

  @override
  Future<Object> insert(Map<String, Object?> document) async {
    final json = _values.write(document);
    final id = json[schema.idName] as int?;
    return _write(() async {
      if (id != null && await _raw(id) != null) {
        throw InspectorException(
          ErrorCodes.invalidRequest,
          'An object with ${schema.idName} $id already exists in "$name"',
          {'table': name},
        );
      }
      await _collection.importJson([json]);
      if (id != null) return id;
      // Auto-increment ids are above every existing id, so the new object
      // is the last one in id order.
      final last =
          await _buildQuery(whereSort: Sort.desc, limit: 1).exportJson();
      return last.single[schema.idName]! as int;
    });
  }

  @override
  Future<bool> update(Object id, Map<String, Object?> changes) {
    final json = _values.write(changes);
    return _write(() async {
      final current = await _raw(_intId(id));
      if (current == null) return false;
      // importJson replaces the object with the same id (a put).
      await _collection.importJson([
        {...current, ...json},
      ]);
      return true;
    });
  }

  @override
  Future<bool> delete(Object id) =>
      _write(() => _collection.delete(_intId(id)));

  @override
  Future<int> clear() => _write(() async {
        final removed = await _collection.count();
        await _collection.clear();
        return removed;
      });

  // ---------------------------------------------------------------------------
  // Native query

  @override
  Future<DocumentPage?> query(RowsQuery query) async {
    // Search stays in the generic engine, which honours masked columns.
    if (query.search != null) return null;

    final conditions = <FilterOperation>[];
    for (final f in query.filters) {
      final condition = _condition(f);
      if (condition == null) return null;
      conditions.add(condition);
    }

    final sortBy = <SortProperty>[];
    var whereSort = Sort.asc;
    for (final s in query.sort) {
      final sort = s.direction == SortDirection.asc ? Sort.asc : Sort.desc;
      if (s.column == schema.idName) {
        // Ids are unique: later keys are irrelevant. Isar sorts stably, so
        // the id order of the where clause breaks ties of earlier keys.
        whereSort = sort;
        break;
      }
      final p = schema.properties[s.column];
      if (p == null || !_sortable.contains(p.type)) return null;
      sortBy.add(SortProperty(property: p.name, sort: sort));
    }

    final filter = switch (conditions.length) {
      0 => null,
      1 => conditions.single,
      _ => FilterGroup.and(conditions),
    };
    final documents = await _export(_buildQuery(
      filter: filter,
      whereSort: whereSort,
      sortBy: sortBy,
      offset: query.offset,
      limit: query.pageSize,
    ));
    final total = await _buildQuery(filter: filter).count();
    return DocumentPage(documents: documents, total: total);
  }

  static const _sortable = {
    IsarType.bool,
    IsarType.byte,
    IsarType.int,
    IsarType.long,
    IsarType.float,
    IsarType.double,
    IsarType.dateTime,
    IsarType.string,
  };

  /// Native equivalent of [f] under the runtime's in-memory semantics, or
  /// `null` when Isar's typed conditions cannot express it exactly.
  FilterOperation? _condition(RowFilter f) {
    final isId = f.column == schema.idName;
    final property = schema.properties[f.column];
    if (!isId && property == null) return null;
    final name = f.column;
    final type = isId ? IsarType.long : property!.type;

    var op = f.operator;
    if (f.value == null && op == FilterOperator.equals) {
      op = FilterOperator.isNull;
    } else if (f.value == null && op == FilterOperator.notEquals) {
      op = FilterOperator.isNotNull;
    }

    switch (op) {
      case FilterOperator.isNull:
        return FilterCondition.isNull(property: name);
      case FilterOperator.isNotNull:
        return FilterCondition.isNotNull(property: name);
      default:
    }
    final target = f.value;
    if (target == null) return null;

    switch (type) {
      case IsarType.string:
        return _stringCondition(name, op, target);
      case IsarType.byte || IsarType.int || IsarType.long:
        return _intCondition(name, op, target);
      case IsarType.bool:
        final value = switch ('$target'.toLowerCase()) {
          'true' => true,
          'false' => false,
          _ => null,
        };
        if (value == null) return null;
        final equal = FilterCondition.equalTo(property: name, value: value);
        return switch (op) {
          FilterOperator.equals => equal,
          FilterOperator.notEquals => FilterGroup.not(equal),
          _ => null,
        };
      default:
        // Floating point (Isar compares with an epsilon), dates (compared as
        // text in memory), lists and embedded objects.
        return null;
    }
  }

  FilterOperation? _stringCondition(
    String name,
    FilterOperator op,
    Object target,
  ) {
    // A numeric target compares numerically with numeric text in memory.
    if (target is num || target is! String) return null;
    switch (op) {
      case FilterOperator.contains ||
            FilterOperator.startsWith ||
            FilterOperator.endsWith:
        if (target.isEmpty) return null;
        return switch (op) {
          FilterOperator.contains => FilterCondition.contains(
              property: name, value: target, caseSensitive: false),
          FilterOperator.startsWith => FilterCondition.startsWith(
              property: name, value: target, caseSensitive: false),
          _ => FilterCondition.endsWith(
              property: name, value: target, caseSensitive: false),
        };
      case FilterOperator.equals || FilterOperator.notEquals:
        // Numeric-looking text is compared numerically in memory.
        if (num.tryParse(target) != null) return null;
        final equal = FilterCondition.equalTo(property: name, value: target);
        return op == FilterOperator.equals ? equal : FilterGroup.not(equal);
      default:
        if (num.tryParse(target) != null) return null;
        return _range(name, op, target);
    }
  }

  FilterOperation? _intCondition(
      String name, FilterOperator op, Object target) {
    final number = switch (target) {
      num() => target,
      String() => num.tryParse(target),
      _ => null,
    };
    if (number == null || number != number.truncate()) return null;
    final value = number.toInt();
    switch (op) {
      case FilterOperator.equals:
        return FilterCondition.equalTo(property: name, value: value);
      case FilterOperator.notEquals:
        return FilterGroup.not(
            FilterCondition.equalTo(property: name, value: value));
      case FilterOperator.contains ||
            FilterOperator.startsWith ||
            FilterOperator.endsWith:
        return null;
      default:
        return _range(name, op, value);
    }
  }

  /// Range condition; Isar orders null below every value, so lower-than
  /// conditions exclude nulls explicitly (as the in-memory engine does).
  FilterOperation? _range(String name, FilterOperator op, Object value) =>
      switch (op) {
        FilterOperator.greaterThan => FilterCondition.greaterThan(
            property: name, value: value, caseSensitive: true),
        FilterOperator.greaterOrEqual => FilterCondition.greaterThan(
            property: name, value: value, include: true, caseSensitive: true),
        FilterOperator.lessThan => FilterGroup.and([
            FilterCondition.isNotNull(property: name),
            FilterCondition.lessThan(
                property: name, value: value, caseSensitive: true),
          ]),
        FilterOperator.lessOrEqual => FilterGroup.and([
            FilterCondition.isNotNull(property: name),
            FilterCondition.lessThan(
                property: name,
                value: value,
                include: true,
                caseSensitive: true),
          ]),
        _ => null,
      };

  // ---------------------------------------------------------------------------

  /// Untyped query over the collection. `buildQuery` is the only way to
  /// query Isar without generated, per-collection query builders; it is
  /// marked experimental by Isar but is what Isar's own inspector uses.
  Query<Object?> _buildQuery({
    List<WhereClause> whereClauses = const [],
    Sort whereSort = Sort.asc,
    FilterOperation? filter,
    List<SortProperty> sortBy = const [],
    int? offset,
    int? limit,
  }) =>
      // ignore: experimental_member_use
      _collection.buildQuery<Object?>(
        // Without a where clause Isar ignores [whereSort].
        whereClauses:
            whereClauses.isEmpty ? const [IdWhereClause.any()] : whereClauses,
        whereSort: whereSort,
        filter: filter,
        sortBy: sortBy,
        offset: offset,
        limit: limit,
      );

  Future<List<Map<String, Object?>>> _export(Query<Object?> query) async => [
        for (final json in await query.exportJson()) _values.read(json),
      ];

  Future<Map<String, Object?>?> _raw(int id) async {
    final found = await _buildQuery(
      whereClauses: [IdWhereClause.equalTo(value: id)],
    ).exportJson();
    return found.isEmpty ? null : found.single;
  }

  Future<T> _write<T>(Future<T> Function() body) async {
    try {
      return await isar.writeTxn(body);
    } on IsarError catch (e) {
      throw InspectorException(ErrorCodes.transactionFailed, e.message);
    }
  }

  int _intId(Object id) =>
      id is int ? id : throw AdapterErrors.invalidKey(name, 'expected an int');
}

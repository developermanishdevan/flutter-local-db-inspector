import 'dart:async';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:realm_dart/realm.dart';

import 'realm_values.dart';

/// Exposes one top-level Realm class as a [DocumentCollection], using
/// Realm's dynamic (untyped) API only.
///
/// Classes without a primary key are read-only: their objects cannot be
/// addressed individually.
class RealmCollection extends DocumentCollection {
  RealmCollection(this.realm, this.schema)
      : _properties = [
          for (final p in schema)
            if (p.propertyType != RealmPropertyType.linkingObjects) p,
        ];

  final Realm realm;
  final SchemaObject schema;

  /// Persisted properties (computed backlinks are left out).
  final List<SchemaProperty> _properties;

  SchemaProperty? get _primaryKey => schema.primaryKey;

  @override
  String get name => schema.name;

  /// The primary key property. Classes without one use their first property
  /// so that no synthetic id column is shown; their rows are not addressable.
  @override
  String get idField =>
      _primaryKey?.name ??
      (_properties.isEmpty ? r'$id' : _properties.first.name);

  @override
  bool get writable => _primaryKey != null;

  @override
  List<ColumnInfo> get fields => [
        for (final p in _properties)
          ColumnInfo(
            name: p.name,
            valueType: RealmValues.valueType(p),
            declaredType: RealmValues.declaredType(p),
            nullable:
                p.optional && p.collectionType == RealmCollectionType.none,
            primaryKeyPosition: p.primaryKey ? 1 : 0,
          ),
      ];

  @override
  List<IndexInfo> get indexes => [
        for (final p in _properties)
          if (p.primaryKey)
            IndexInfo(
              name: '$name.${p.name}',
              table: name,
              columns: [p.name],
              unique: true,
              origin: 'pk',
            )
          else if (p.indexType != null)
            IndexInfo(
              name: '$name.${p.name}',
              table: name,
              columns: [p.name],
              origin: p.indexType == RealmIndexType.fullText ? 'fts' : 'c',
            ),
      ];

  RealmResults<RealmObject> _all() {
    _ensureOpen();
    return realm.dynamic.all(name);
  }

  void _ensureOpen() {
    if (realm.isClosed) {
      throw InspectorException(
        ErrorCodes.databaseNotFound,
        'The Realm has been closed',
      );
    }
  }

  Map<String, Object?> _document(RealmObject object) => {
        for (final p in _properties) p.name: RealmValues.read(object, p),
      };

  /// Reads `results[offset, offset + limit)` lazily; Realm results are
  /// live views, so only the requested objects are materialized.
  List<Map<String, Object?>> _page(
    RealmResults<RealmObject> results,
    int offset,
    int limit,
  ) {
    final end = (offset + limit).clamp(0, results.length);
    return [
      for (var i = offset; i < end; i++) _document(results[i]),
    ];
  }

  @override
  Future<int> count() async => _all().length;

  @override
  Future<List<Map<String, Object?>>> list({
    required int offset,
    required int limit,
  }) async =>
      _page(_all(), offset, limit);

  /// Converts an inspector row id back into the primary key's Dart type.
  Object _primaryKeyValue(Object id) {
    final pk = _primaryKey;
    if (pk == null) {
      throw AdapterErrors.invalidKey(name, 'the class has no primary key');
    }
    final value = RealmValues.toRealm(name, pk, id);
    if (value == null) throw AdapterErrors.invalidKey(name, 'null id');
    return value;
  }

  RealmObject? _find(Object id) {
    _ensureOpen();
    if (_primaryKey == null) return null;
    final Object key;
    try {
      key = _primaryKeyValue(id);
    } on InspectorException {
      throw AdapterErrors.invalidKey(
        name,
        'expected a ${RealmValues.declaredType(_primaryKey!)} "$idField"',
      );
    }
    return realm.dynamic.find(name, key);
  }

  @override
  Future<Map<String, Object?>?> get(Object id) async {
    final object = _find(id);
    return object == null ? null : _document(object);
  }

  SchemaProperty _property(String field) =>
      _propertyOrNull(field) ??
      (throw AdapterErrors.columnNotFound(name, field));

  /// Validates and converts [values] for a write.
  Map<SchemaProperty, Object?> _converted(Map<String, Object?> values) => {
        for (final e in values.entries)
          _property(e.key):
              RealmValues.toRealm(name, _property(e.key), e.value),
      };

  T _write<T>(T Function() body) {
    _ensureOpen();
    if (realm.isInTransaction) {
      throw InspectorException(
        ErrorCodes.databaseBusy,
        'The Realm is in a write transaction; try again.',
      );
    }
    try {
      return realm.write(body);
    } on RealmException catch (e) {
      throw InspectorException(ErrorCodes.transactionFailed, e.message);
    }
  }

  @override
  Future<Object> insert(Map<String, Object?> document) async {
    final pk = _primaryKey;
    if (pk == null) {
      throw InspectorException(
        ErrorCodes.unsupportedOperation,
        'Class "$name" has no primary key; objects cannot be inserted.',
      );
    }
    final values = Map.of(document);
    final key = values.remove(pk.name) ??
        switch (pk.propertyType) {
          RealmPropertyType.objectid => ObjectId(),
          RealmPropertyType.uuid => Uuid.v4(),
          _ => throw InspectorException(
              ErrorCodes.invalidRequest,
              'A value for the primary key "${pk.name}" is required.',
            ),
        };
    final primaryKey = _primaryKeyValue(key);
    final converted = _converted(values);
    _ensureOpen();
    if (realm.dynamic.find(name, primaryKey) != null) {
      throw InspectorException(
        ErrorCodes.invalidRequest,
        'An object with ${pk.name} = $primaryKey already exists in "$name".',
      );
    }
    _write(() {
      final object = realm.dynamic.create(name, primaryKey: primaryKey);
      for (final e in converted.entries) {
        RealmObjectBase.set<Object?>(object, e.key.name, e.value);
      }
    });
    // Ids are exchanged as int or String (ObjectId/Uuid are stringified).
    return RealmValues.toDisplay(primaryKey)!;
  }

  @override
  Future<bool> update(Object id, Map<String, Object?> changes) async {
    final converted = _converted(changes);
    final object = _find(id);
    if (object == null) return false;
    _write(() {
      for (final e in converted.entries) {
        RealmObjectBase.set<Object?>(object, e.key.name, e.value);
      }
    });
    return true;
  }

  @override
  Future<bool> delete(Object id) async {
    final object = _find(id);
    if (object == null) return false;
    _write(() => realm.delete(object));
    return true;
  }

  @override
  Future<int> clear() async {
    final results = _all();
    return _write(() {
      final count = results.length;
      realm.deleteMany(results);
      return count;
    });
  }

  // ---------------------------------------------------------------------------
  // Native queries (Realm Query Language)

  @override
  Future<DocumentPage?> query(RowsQuery query) async {
    // Search stays in the generic engine, which honours masked columns.
    if (query.search != null) return null;

    final predicates = <String>[];
    final args = <Object>[];
    for (final f in query.filters) {
      final predicate = _predicate(f, args);
      if (predicate == null) return null;
      predicates.add(predicate);
    }

    final sort = <String>[];
    for (final s in query.sort) {
      final p = _propertyOrNull(s.column);
      if (p == null ||
          !_sortable.contains(p.propertyType) ||
          !RealmValues.isPrimitive(p)) {
        return null;
      }
      sort.add(
          '${p.name} ${s.direction == SortDirection.asc ? 'ASC' : 'DESC'}');
    }

    final rql = StringBuffer(
      predicates.isEmpty ? 'TRUEPREDICATE' : predicates.join(' AND '),
    );
    if (sort.isNotEmpty) rql.write(' SORT(${sort.join(', ')})');

    final RealmResults<RealmObject> results;
    try {
      results = _all().query(rql.toString(), args);
    } on RealmException {
      return null; // Not expressible natively; evaluate in memory instead.
    }
    return DocumentPage(
      documents: _page(results, query.offset, query.pageSize),
      total: results.length,
    );
  }

  SchemaProperty? _propertyOrNull(String column) {
    for (final p in _properties) {
      if (p.name == column) return p;
    }
    return null;
  }

  /// String (and decimal/id) ordering is left to the in-memory engine:
  /// Realm's string collation is not guaranteed to match the code-unit order
  /// the generic engine uses.
  static const _sortable = {
    RealmPropertyType.int,
    RealmPropertyType.bool,
    RealmPropertyType.float,
    RealmPropertyType.double,
    RealmPropertyType.timestamp,
  };

  /// RQL equivalent of [f] under the runtime's in-memory semantics, or
  /// `null` when RQL cannot express it exactly.
  String? _predicate(RowFilter f, List<Object> args) {
    final p = _propertyOrNull(f.column);
    if (p == null || !RealmValues.isPrimitive(p)) return null;
    final field = p.name;

    var op = f.operator;
    if (f.value == null && op == FilterOperator.equals) {
      op = FilterOperator.isNull;
    } else if (f.value == null && op == FilterOperator.notEquals) {
      op = FilterOperator.isNotNull;
    }
    final nullable = p.optional || p.propertyType == RealmPropertyType.mixed;
    if (op == FilterOperator.isNull) {
      return nullable ? '$field == nil' : 'FALSEPREDICATE';
    }
    if (op == FilterOperator.isNotNull) {
      return nullable ? '$field != nil' : 'TRUEPREDICATE';
    }

    final target = f.value;
    if (target == null) return null;

    String bind(String rqlOp, Object value) {
      args.add(value);
      return '$field $rqlOp \$${args.length - 1}';
    }

    switch (p.propertyType) {
      case RealmPropertyType.string:
        // Realm's [c] folds ASCII case like Dart's toLowerCase; other
        // scripts (and the empty pattern) are left to the in-memory engine.
        if (target is! String) return null;
        final ascii =
            target.isNotEmpty && target.codeUnits.every((c) => c < 128);
        if (!ascii &&
            op != FilterOperator.equals &&
            op != FilterOperator.notEquals) {
          return null;
        }
        return switch (op) {
          FilterOperator.equals => bind('==', target),
          FilterOperator.notEquals => bind('!=', target),
          FilterOperator.contains => bind('CONTAINS[c]', target),
          FilterOperator.startsWith => bind('BEGINSWITH[c]', target),
          FilterOperator.endsWith => bind('ENDSWITH[c]', target),
          // In memory, numeric-looking targets compare numerically.
          _ => null,
        };
      case RealmPropertyType.int ||
            RealmPropertyType.float ||
            RealmPropertyType.double:
        final number = switch (target) {
          num() => target,
          String() => num.tryParse(target.trim()),
          _ => null,
        };
        if (number == null) return null;
        final Object value;
        if (p.propertyType == RealmPropertyType.int) {
          if (number is! int) return null;
          value = number;
        } else {
          value = number.toDouble();
        }
        final rqlOp = switch (op) {
          FilterOperator.equals => '==',
          FilterOperator.notEquals => '!=',
          FilterOperator.greaterThan => '>',
          FilterOperator.lessThan => '<',
          FilterOperator.greaterOrEqual => '>=',
          FilterOperator.lessOrEqual => '<=',
          _ => null,
        };
        return rqlOp == null ? null : bind(rqlOp, value);
      case RealmPropertyType.bool:
        final flag = switch (target) {
          bool() => target,
          String() => switch (target.toLowerCase()) {
              'true' => true,
              'false' => false,
              _ => null,
            },
          _ => null,
        };
        if (flag == null) return null;
        return switch (op) {
          FilterOperator.equals => bind('==', flag),
          FilterOperator.notEquals => bind('!=', flag),
          _ => null,
        };
      default:
        return null;
    }
  }
}

import '../json.dart';
import '../value.dart';

/// Kinds of browsable entities. Non-SQL engines use [collection], [box] or
/// [store] instead of being forced into a table model.
enum EntityKind {
  table,
  view,
  collection,
  box,
  store;

  static EntityKind fromWire(String? name) =>
      values.firstWhere((k) => k.name == name, orElse: () => EntityKind.table);
}

/// A table/view/collection listed by `schema.list`.
final class EntitySummary {
  const EntitySummary({
    required this.name,
    required this.kind,
    this.rowCount,
    this.readOnly = false,
  });

  factory EntitySummary.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return EntitySummary(
      name: r.string('name'),
      kind: EntityKind.fromWire(r.optString('kind')),
      rowCount: r.optInt('rowCount'),
      readOnly: r.boolean('readOnly'),
    );
  }

  final String name;
  final EntityKind kind;
  final int? rowCount;

  /// True for entities whose rows cannot be edited (e.g. SQL views).
  final bool readOnly;

  JsonMap toJson() => {
        'name': name,
        'kind': kind.name,
        if (rowCount != null) 'rowCount': rowCount,
        'readOnly': readOnly,
      };
}

final class IndexInfo {
  const IndexInfo({
    required this.name,
    required this.table,
    required this.columns,
    this.unique = false,
    this.origin,
    this.partial = false,
    this.sql,
  });

  factory IndexInfo.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return IndexInfo(
      name: r.string('name'),
      table: r.string('table'),
      columns: r.strings('columns'),
      unique: r.boolean('unique'),
      origin: r.optString('origin'),
      partial: r.boolean('partial'),
      sql: r.optString('sql'),
    );
  }

  final String name;
  final String table;
  final List<String> columns;
  final bool unique;

  /// How the index was created (`c` = CREATE INDEX, `u` = UNIQUE, `pk`).
  final String? origin;
  final bool partial;
  final String? sql;

  JsonMap toJson() => {
        'name': name,
        'table': table,
        'columns': columns,
        'unique': unique,
        if (origin != null) 'origin': origin,
        'partial': partial,
        if (sql != null) 'sql': sql,
      };
}

final class TriggerInfo {
  const TriggerInfo({required this.name, required this.table, this.sql});

  factory TriggerInfo.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return TriggerInfo(
      name: r.string('name'),
      table: r.string('table'),
      sql: r.optString('sql'),
    );
  }

  final String name;
  final String table;
  final String? sql;

  JsonMap toJson() => {
        'name': name,
        'table': table,
        if (sql != null) 'sql': sql,
      };
}

/// Result of `schema.list`.
final class SchemaOverview {
  const SchemaOverview({
    required this.entities,
    this.indexes = const [],
    this.triggers = const [],
  });

  factory SchemaOverview.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return SchemaOverview(
      entities: r.objects('entities', EntitySummary.fromJson),
      indexes: r.objects('indexes', IndexInfo.fromJson),
      triggers: r.objects('triggers', TriggerInfo.fromJson),
    );
  }

  final List<EntitySummary> entities;
  final List<IndexInfo> indexes;
  final List<TriggerInfo> triggers;

  JsonMap toJson() => {
        'entities': [for (final e in entities) e.toJson()],
        'indexes': [for (final i in indexes) i.toJson()],
        'triggers': [for (final t in triggers) t.toJson()],
      };
}

final class ColumnInfo {
  const ColumnInfo({
    required this.name,
    required this.valueType,
    this.declaredType = '',
    this.nullable = true,
    this.primaryKeyPosition = 0,
    this.defaultValue,
    this.autoIncrement = false,
    this.generated = false,
  });

  factory ColumnInfo.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return ColumnInfo(
      name: r.string('name'),
      valueType: DbValueType.fromWire(r.optString('valueType')),
      declaredType: r.optString('declaredType') ?? '',
      nullable: r.boolean('nullable', fallback: true),
      primaryKeyPosition: r.optInt('primaryKeyPosition') ?? 0,
      defaultValue: r.optString('defaultValue'),
      autoIncrement: r.boolean('autoIncrement'),
      generated: r.boolean('generated'),
    );
  }

  final String name;
  final DbValueType valueType;

  /// Type as declared by the engine (e.g. `VARCHAR(20)`).
  final String declaredType;
  final bool nullable;

  /// 1-based position in the primary key, or 0 when not part of it.
  final int primaryKeyPosition;

  /// Default value expression as text.
  final String? defaultValue;

  /// Value is assigned by the engine when omitted on insert.
  final bool autoIncrement;

  /// Computed column that cannot be written.
  final bool generated;

  bool get isPrimaryKey => primaryKeyPosition > 0;

  JsonMap toJson() => {
        'name': name,
        'valueType': valueType.wireName,
        'declaredType': declaredType,
        'nullable': nullable,
        'primaryKeyPosition': primaryKeyPosition,
        if (defaultValue != null) 'defaultValue': defaultValue,
        'autoIncrement': autoIncrement,
        'generated': generated,
      };
}

final class ForeignKeyInfo {
  const ForeignKeyInfo({
    required this.columns,
    required this.referencedTable,
    required this.referencedColumns,
    this.onUpdate = 'NO ACTION',
    this.onDelete = 'NO ACTION',
  });

  factory ForeignKeyInfo.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return ForeignKeyInfo(
      columns: r.strings('columns'),
      referencedTable: r.string('referencedTable'),
      referencedColumns: r.strings('referencedColumns'),
      onUpdate: r.optString('onUpdate') ?? 'NO ACTION',
      onDelete: r.optString('onDelete') ?? 'NO ACTION',
    );
  }

  final List<String> columns;
  final String referencedTable;
  final List<String> referencedColumns;
  final String onUpdate;
  final String onDelete;

  JsonMap toJson() => {
        'columns': columns,
        'referencedTable': referencedTable,
        'referencedColumns': referencedColumns,
        'onUpdate': onUpdate,
        'onDelete': onDelete,
      };
}

/// How rows of an entity are identified for edits.
enum RowKeyKind {
  /// Rows are addressed by `{"rowid": n}`.
  rowid,

  /// Rows are addressed by every primary key column.
  primaryKey,

  /// Engine-defined key (e.g. Hive box keys) under `{"key": …}`.
  key,

  /// Rows cannot be addressed (e.g. views); they are read-only.
  none;

  static RowKeyKind fromWire(String? name) =>
      values.firstWhere((k) => k.name == name, orElse: () => RowKeyKind.none);
}

/// Result of `schema.table`.
final class TableSchema {
  const TableSchema({
    required this.name,
    required this.kind,
    required this.columns,
    this.rowKey = RowKeyKind.none,
    this.foreignKeys = const [],
    this.indexes = const [],
    this.triggers = const [],
    this.sql,
  });

  factory TableSchema.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return TableSchema(
      name: r.string('name'),
      kind: EntityKind.fromWire(r.optString('kind')),
      columns: r.objects('columns', ColumnInfo.fromJson),
      rowKey: RowKeyKind.fromWire(r.optString('rowKey')),
      foreignKeys: r.objects('foreignKeys', ForeignKeyInfo.fromJson),
      indexes: r.objects('indexes', IndexInfo.fromJson),
      triggers: r.objects('triggers', TriggerInfo.fromJson),
      sql: r.optString('sql'),
    );
  }

  final String name;
  final EntityKind kind;
  final List<ColumnInfo> columns;
  final RowKeyKind rowKey;
  final List<ForeignKeyInfo> foreignKeys;
  final List<IndexInfo> indexes;
  final List<TriggerInfo> triggers;

  /// The DDL statement, when the engine has one.
  final String? sql;

  ColumnInfo? column(String name) {
    for (final c in columns) {
      if (c.name == name) return c;
    }
    return null;
  }

  JsonMap toJson() => {
        'name': name,
        'kind': kind.name,
        'columns': [for (final c in columns) c.toJson()],
        'rowKey': rowKey.name,
        'foreignKeys': [for (final f in foreignKeys) f.toJson()],
        'indexes': [for (final i in indexes) i.toJson()],
        'triggers': [for (final t in triggers) t.toJson()],
        if (sql != null) 'sql': sql,
      };
}

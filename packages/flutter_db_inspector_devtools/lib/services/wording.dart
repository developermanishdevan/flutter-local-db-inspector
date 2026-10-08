import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

/// Terminology by data model and entity kind, so a Hive box never shows up
/// as a "table with rows".
abstract final class Wording {
  /// `row` / `object` / `entry`.
  static String record(DbDataModel model, {bool plural = false}) =>
      switch (model) {
        DbDataModel.relational => plural ? 'rows' : 'row',
        DbDataModel.document => plural ? 'objects' : 'object',
        DbDataModel.keyValue => plural ? 'entries' : 'entry',
      };

  static String recordCount(DbDataModel model, int count) =>
      '${WireValues.formatCount(count)} ${record(model, plural: count != 1)}';

  /// `Tables` / `Collections` / `Boxes` for a whole database.
  static String entities(DbDataModel model) => switch (model) {
        DbDataModel.relational => 'Tables',
        DbDataModel.document => 'Collections',
        DbDataModel.keyValue => 'Boxes',
      };

  /// Tree group label for an entity kind.
  static String group(EntityKind kind) => switch (kind) {
        EntityKind.table => 'Tables',
        EntityKind.view => 'Views',
        EntityKind.collection => 'Collections',
        EntityKind.box => 'Boxes',
        EntityKind.store => 'Stores',
      };

  /// Fields of a record: `columns` / `fields`.
  static String fields(DbDataModel model) =>
      model == DbDataModel.relational ? 'columns' : 'fields';

  /// Order of entity groups in the tree: tables first.
  static const groupOrder = [
    EntityKind.table,
    EntityKind.view,
    EntityKind.collection,
    EntityKind.box,
    EntityKind.store,
  ];

  /// "INDEX_NAME: message" for errors shown to the user.
  static String error(Object error) => switch (error) {
        InspectorClientException(:final code, :final message) =>
          code.isEmpty ? message : '$code: $message',
        _ => '$error',
      };
}

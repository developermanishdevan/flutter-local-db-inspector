import 'dart:async';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

/// A collection of objects/documents (an Isar collection, an ObjectBox box,
/// a Realm class, a Sembast store, ...) that [DocumentAdapter] can inspect.
///
/// Documents are exchanged as JSON-like maps that include [idField].
abstract class DocumentCollection {
  String get name;

  /// Field holding the object id inside documents.
  String get idField => 'id';

  /// Declared fields for engines with a schema. Leave empty for schemaless
  /// engines; fields are then inferred from stored documents.
  List<ColumnInfo> get fields => const [];

  List<IndexInfo> get indexes => const [];

  bool get writable => true;

  Future<int> count();

  /// Documents in id order.
  Future<List<Map<String, Object?>>> list({
    required int offset,
    required int limit,
  });

  Future<Map<String, Object?>?> get(Object id);

  /// Inserts a document and returns its id.
  Future<Object> insert(Map<String, Object?> document);

  /// Applies [changes] to the document; returns `false` when it is missing.
  Future<bool> update(Object id, Map<String, Object?> changes);

  Future<bool> delete(Object id);

  /// Removes every document and returns how many were removed.
  Future<int> clear();

  /// Optional native implementation of filtering/sorting/search. Return
  /// `null` to let [DocumentAdapter] evaluate the query in memory.
  Future<DocumentPage?> query(RowsQuery query) async => null;
}

/// Result of a native [DocumentCollection.query].
final class DocumentPage {
  const DocumentPage({required this.documents, required this.total});

  final List<Map<String, Object?>> documents;
  final int total;
}

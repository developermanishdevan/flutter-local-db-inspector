import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:objectbox/objectbox.dart';

/// An ObjectBox [Box] exposed as a [DocumentCollection].
///
/// ObjectBox's Dart API is fully typed (generated per entity) and offers no
/// untyped access, so each box is bound with conversions the app provides:
///
/// ```dart
/// ObjectBoxCollection<Task>(
///   store.box<Task>(),
///   name: 'Task',
///   toJson: (t) => {'id': t.id, 'title': t.title, 'done': t.done},
///   fromJson: (j) => Task(
///     id: j['id'] as int? ?? 0,
///     title: j['title'] as String? ?? '',
///     done: j['done'] as bool? ?? false,
///   ),
///   getId: (t) => t.id,
/// )
/// ```
///
/// [toJson] must include the id under [idField]. [fromJson] receives the
/// full document on insert/update (stored values merged with the edits) and
/// should treat a missing id as `0`, ObjectBox's "assign a new id".
/// Leave [fields] empty to infer columns from stored objects.
///
/// Filtering, sorting and search are evaluated in memory by the generic
/// engine (ObjectBox conditions need the generated `Entity_` properties);
/// paging and counting use ObjectBox queries.
final class ObjectBoxCollection<T> extends DocumentCollection {
  ObjectBoxCollection(
    this.box, {
    required this.name,
    required Map<String, Object?> Function(T) toJson,
    required T Function(Map<String, Object?>) fromJson,
    required int Function(T) getId,
    this.fields = const [],
    this.idField = 'id',
  })  : _toJson = toJson,
        _fromJson = fromJson,
        _getId = getId;

  final Box<T> box;

  @override
  final String name;

  @override
  final List<ColumnInfo> fields;

  @override
  final String idField;

  final Map<String, Object?> Function(T) _toJson;
  final T Function(Map<String, Object?>) _fromJson;
  final int Function(T) _getId;

  @override
  Future<int> count() async => box.count();

  @override
  Future<List<Map<String, Object?>>> list({
    required int offset,
    required int limit,
  }) async {
    // Queries without an order return objects in id order.
    final query = box.query().build()
      ..offset = offset
      ..limit = limit;
    try {
      return [for (final o in query.find()) _document(o)];
    } finally {
      query.close();
    }
  }

  @override
  Future<Map<String, Object?>?> get(Object id) async {
    final object = box.get(_intId(id));
    return object == null ? null : _document(object);
  }

  @override
  Future<Object> insert(Map<String, Object?> document) async {
    final id = document[idField];
    if (id != null && id != 0 && box.contains(_intId(id))) {
      throw InspectorException(
        ErrorCodes.invalidRequest,
        'An object with $idField $id already exists in "$name"',
        {'table': name},
      );
    }
    return _guard(() => box.put(_fromJson(document), mode: PutMode.insert));
  }

  @override
  Future<bool> update(Object id, Map<String, Object?> changes) async {
    final current = box.get(_intId(id));
    if (current == null) return false;
    _guard(() => box.put(
          _fromJson({..._document(current), ...changes, idField: id}),
          mode: PutMode.update,
        ));
    return true;
  }

  @override
  Future<bool> delete(Object id) async => box.remove(_intId(id));

  @override
  Future<int> clear() async => box.removeAll();

  Map<String, Object?> _document(T object) =>
      {idField: _getId(object), ..._toJson(object)};

  int _intId(Object id) =>
      id is int ? id : throw AdapterErrors.invalidKey(name, 'expected an int');

  R _guard<R>(R Function() write) {
    try {
      return write();
    } on ObjectBoxException catch (e) {
      throw InspectorException(ErrorCodes.transactionFailed, e.message);
    } on TypeError catch (e) {
      // fromJson could not convert an edited value.
      throw InspectorException(
        ErrorCodes.invalidRequest,
        'Invalid value for "$name": $e',
      );
    } on ArgumentError catch (e) {
      // ObjectBox rejects e.g. ids it did not assign with an ArgumentError.
      throw InspectorException(ErrorCodes.invalidRequest, '${e.message}');
    }
  }
}

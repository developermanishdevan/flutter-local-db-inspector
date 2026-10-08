import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';

/// Real (in-memory) [KeyValueStore] used to exercise the key/value engine.
final class MemoryStore extends KeyValueStore {
  MemoryStore(this.name, [Map<Object, Object?>? data]) : data = data ?? {};

  @override
  final String name;
  final Map<Object, Object?> data;

  @override
  int get length => data.length;

  @override
  Iterable<Object> get keys => data.keys;

  @override
  bool containsKey(Object key) => data.containsKey(key);

  @override
  Object? get(Object key) => data[key];

  @override
  Future<void> put(Object key, Object? value) async => data[key] = value;

  @override
  Future<void> delete(Object key) async => data.remove(key);

  @override
  Future<int> clear() async {
    final n = data.length;
    data.clear();
    return n;
  }
}

/// Real (in-memory) [DocumentCollection].
class MemoryCollection extends DocumentCollection {
  MemoryCollection(this.name, {this.fields = const []});

  @override
  final String name;
  @override
  final List<ColumnInfo> fields;
  final Map<int, Map<String, Object?>> docs = {};
  int _nextId = 1;

  @override
  Future<int> count() async => docs.length;

  @override
  Future<List<Map<String, Object?>>> list(
          {required int offset, required int limit}) async =>
      (docs.keys.toList()..sort())
          .skip(offset)
          .take(limit)
          .map((id) => docs[id]!)
          .toList();

  @override
  Future<Map<String, Object?>?> get(Object id) async => docs[id];

  @override
  Future<Object> insert(Map<String, Object?> document) async {
    final id = document['id'] as int? ?? _nextId;
    _nextId = id + 1;
    docs[id] = {...document, 'id': id};
    return id;
  }

  @override
  Future<bool> update(Object id, Map<String, Object?> changes) async {
    final doc = docs[id];
    if (doc == null) return false;
    docs[id as int] = {...doc, ...changes};
    return true;
  }

  @override
  Future<bool> delete(Object id) async => docs.remove(id) != null;

  @override
  Future<int> clear() async {
    final n = docs.length;
    docs.clear();
    return n;
  }
}

final class Person {
  Person(this.name, this.age);

  final String name;
  final int age;

  Map<String, Object?> toJson() => {'name': name, 'age': age};
}

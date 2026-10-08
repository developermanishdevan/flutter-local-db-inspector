import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:get_storage/get_storage.dart';

/// [KeyValueStore] binding for a [GetStorage] container.
///
/// GetStorage keeps every container in memory and persists it as JSON, so
/// reads are synchronous. [GetStorage] does not expose its container name;
/// pass it as [name].
///
/// Custom objects written by the app are shown through their `toJson()`.
/// They are not overwritten with plain JSON, which would change their type
/// for the running app (see [KeyValueStore.decodeForWrite]).
final class GetStorageStore extends KeyValueStore {
  GetStorageStore(this.storage, {this.name = 'GetStorage'});

  final GetStorage storage;

  @override
  final String name;

  Iterable<String> get _keys => storage.getKeys<Iterable<String>>();

  @override
  int get length => _keys.length;

  @override
  Iterable<Object> get keys => _keys;

  @override
  bool containsKey(Object key) => key is String && _keys.contains(key);

  @override
  Object? get(Object key) => key is String ? storage.read<Object?>(key) : null;

  @override
  Future<void> put(Object key, Object? value) {
    if (key is! String) {
      throw InspectorException(
        ErrorCodes.invalidRequest,
        'GetStorage keys must be strings',
      );
    }
    return storage.write(key, value);
  }

  @override
  Future<void> delete(Object key) async {
    if (key is String) await storage.remove(key);
  }

  @override
  Future<int> clear() async {
    final count = length;
    await storage.erase();
    return count;
  }

  @override
  Object? decodeForWrite(Object? value, {Object? previous}) {
    if (!_isJson(previous)) {
      throw InspectorException(
        ErrorCodes.unsupportedOperation,
        'The current value in "$name" is a ${previous.runtimeType} object; '
        'writing plain JSON over it would change its type for the app',
      );
    }
    if (!_isJson(value)) {
      throw InspectorException(
        ErrorCodes.invalidRequest,
        'GetStorage persists values as JSON; '
        '${InMemoryQuery.typeName(value)} is not supported',
      );
    }
    return value;
  }

  static bool _isJson(Object? value) => switch (value) {
        null || bool() || num() || String() => true,
        List() => value.every(_isJson),
        Map() => value.values.every(_isJson),
        _ => false,
      };
}

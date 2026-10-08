import 'dart:async';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// [KeyValueStore] binding for [FlutterSecureStorage].
///
/// Values are secrets, so they are returned as [MaskedValue] unless
/// [revealValues] is `true`: rows show them as masked and `value.read`
/// refuses to return them. Masked stores never keep secret values in memory.
///
/// [FlutterSecureStorage] can only list keys asynchronously (`readAll`)
/// while [KeyValueStore.keys] is synchronous, so the keys are cached and
/// reloaded by [refresh]; [SecureStorageAdapter] refreshes at the start of
/// every request.
///
/// Values written through the inspector must be strings.
final class SecureStorageStore extends KeyValueStore {
  SecureStorageStore(
    this.storage, {
    this.revealValues = false,
    this.name = defaultName,
  });

  /// Entity name used when none is given.
  static const defaultName = 'secure_storage';

  final FlutterSecureStorage storage;

  /// Whether values are shown in clear text. Off by default.
  final bool revealValues;

  @override
  final String name;

  List<String> _keys = const [];

  /// Reloads the cached key list from the platform.
  Future<void> refresh() async {
    final all = await storage.readAll();
    _keys = all.keys.toList()..sort();
  }

  @override
  int get length => _keys.length;

  @override
  Iterable<Object> get keys => _keys;

  @override
  bool containsKey(Object key) => _keys.contains(key);

  @override
  FutureOr<Object?> get(Object key) {
    if (!revealValues) return const MaskedValue();
    return key is String ? storage.read(key: key) : null;
  }

  @override
  Future<void> put(Object key, Object? value) async {
    if (key is! String) {
      throw InspectorException(
        ErrorCodes.invalidRequest,
        'Secure storage keys must be strings',
      );
    }
    await storage.write(key: key, value: decodeForWrite(value)! as String);
    if (!_keys.contains(key)) _keys = [..._keys, key]..sort();
  }

  @override
  Future<void> delete(Object key) async {
    if (key is! String) return;
    await storage.delete(key: key);
    _keys = [..._keys]..remove(key);
  }

  @override
  Future<int> clear() async {
    await refresh();
    final count = _keys.length;
    await storage.deleteAll();
    _keys = const [];
    return count;
  }

  @override
  Object? decodeForWrite(Object? value, {Object? previous}) {
    if (value is String) return value;
    throw InspectorException(
      ErrorCodes.invalidRequest,
      'Secure storage only stores strings, not '
      '${InMemoryQuery.typeName(value)}',
    );
  }
}

import 'dart:async';

/// A named key/value collection (a Hive box, SharedPreferences, secure
/// storage, ...) that [KeyValueAdapter] can inspect.
abstract class KeyValueStore {
  String get name;

  /// Number of entries.
  int get length;

  /// Keys in storage order. Keys must be JSON primitives (`int`, `String`).
  Iterable<Object> get keys;

  bool containsKey(Object key);

  /// Returns the value for [key]. Return `MaskedValue()` to hide a secret:
  /// it is shown as masked and `value.read` refuses to return it.
  FutureOr<Object?> get(Object key);

  Future<void> put(Object key, Object? value);

  Future<void> delete(Object key);

  /// Removes every entry and returns how many were removed.
  Future<int> clear();

  /// Whether this store accepts writes.
  bool get writable => true;

  /// Converts a value received from a client (JSON-like) into the value to
  /// store. [previous] is the current value, if any. The default accepts
  /// JSON-native values and refuses to overwrite custom objects.
  Object? decodeForWrite(Object? value, {Object? previous}) => value;
}

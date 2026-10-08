import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [KeyValueStore] binding for SharedPreferences.
///
/// Supports the three APIs of `package:shared_preferences`:
///
/// * [SharedPreferencesStore.legacy] — [SharedPreferences], whose in-memory
///   cache is read synchronously.
/// * [SharedPreferencesStore.withCache] — [SharedPreferencesWithCache], also
///   read from its cache.
/// * [SharedPreferencesStore.async] — [SharedPreferencesAsync], which has no
///   cache. Because [KeyValueStore.keys] is synchronous, the store keeps a
///   snapshot of all entries that [refresh] reloads from the platform;
///   [SharedPreferencesAdapter] refreshes it at the start of every request,
///   so each request sees current data.
///
/// Values are `bool`, `int`, `double`, `String` or `List<String>`. Updates
/// keep the type of the current value (an `int` stays an `int`); values that
/// do not fit are rejected with [ErrorCodes.invalidRequest]. Inserts infer
/// the type from the value, a list of strings becoming a string list.
final class SharedPreferencesStore extends KeyValueStore {
  /// Binds the legacy [SharedPreferences] API.
  SharedPreferencesStore.legacy(SharedPreferences prefs,
      {this.name = defaultName})
      : _backend = _LegacyBackend(prefs);

  /// Binds [SharedPreferencesWithCache]. Keys outside its allow list cannot
  /// be written.
  SharedPreferencesStore.withCache(
    SharedPreferencesWithCache prefs, {
    this.name = defaultName,
  }) : _backend = _CachedBackend(prefs);

  /// Binds [SharedPreferencesAsync], optionally restricted to [allowList].
  /// Call [refresh] before reading.
  SharedPreferencesStore.async(
    SharedPreferencesAsync prefs, {
    Set<String>? allowList,
    this.name = defaultName,
  }) : _backend = _AsyncBackend(prefs, allowList);

  /// Entity name used when none is given.
  static const defaultName = 'shared_preferences';

  @override
  final String name;

  final _Backend _backend;

  /// Reloads the snapshot of a [SharedPreferencesAsync] store. A no-op for
  /// the cached APIs, whose cache is the app's own view of the data.
  Future<void> refresh() => _backend.refresh();

  @override
  int get length => _backend.keys.length;

  @override
  Iterable<Object> get keys => _backend.keys;

  @override
  bool containsKey(Object key) => key is String && _backend.contains(key);

  @override
  Object? get(Object key) => key is String ? _backend.get(key) : null;

  @override
  Future<void> put(Object key, Object? value) async {
    if (key is! String) {
      throw InspectorException(
        ErrorCodes.invalidRequest,
        'SharedPreferences keys must be strings',
      );
    }
    try {
      switch (value) {
        case final bool v:
          await _backend.setBool(key, v);
        case final int v:
          await _backend.setInt(key, v);
        case final double v:
          await _backend.setDouble(key, v);
        case final String v:
          await _backend.setString(key, v);
        case final List<String> v:
          await _backend.setStringList(key, v);
        default:
          throw _unsupportedValue(value);
      }
    } on ArgumentError catch (e) {
      // SharedPreferencesWithCache rejects keys outside its allow list.
      throw InspectorException(ErrorCodes.invalidRequest, '${e.message}');
    }
  }

  @override
  Future<void> delete(Object key) async {
    if (key is String) await _backend.remove(key);
  }

  @override
  Future<int> clear() async {
    final count = _backend.keys.length;
    await _backend.clear();
    return count;
  }

  @override
  Object? decodeForWrite(Object? value, {Object? previous}) {
    switch (previous) {
      case null:
        return _infer(value);
      case bool():
        return switch (value) {
          final bool v => v,
          'true' => true,
          'false' => false,
          _ => throw _mismatch('bool', value),
        };
      case int():
        return switch (value) {
          final int v => v,
          final double v when v == v.truncateToDouble() && v.isFinite =>
            v.toInt(),
          final String v when int.tryParse(v.trim()) != null =>
            int.parse(v.trim()),
          _ => throw _mismatch('int', value),
        };
      case double():
        return switch (value) {
          final num v => v.toDouble(),
          final String v when double.tryParse(v.trim()) != null =>
            double.parse(v.trim()),
          _ => throw _mismatch('double', value),
        };
      case String():
        return value is String ? value : throw _mismatch('String', value);
      case List():
        return _stringList(value) ?? (throw _mismatch('List<String>', value));
      default:
        throw _mismatch(InMemoryQuery.typeName(previous), value);
    }
  }

  static Object? _infer(Object? value) => switch (value) {
        bool() || int() || double() || String() => value,
        List() => _stringList(value) ?? (throw _unsupportedValue(value)),
        _ => throw _unsupportedValue(value),
      };

  static List<String>? _stringList(Object? value) =>
      value is List && value.every((e) => e is String)
          ? List<String>.from(value)
          : null;

  static InspectorException _mismatch(String type, Object? value) =>
      InspectorException(
        ErrorCodes.invalidRequest,
        'The current value is a $type; '
        '${InMemoryQuery.typeName(value)} "$value" cannot be stored as $type',
      );

  static InspectorException _unsupportedValue(Object? value) =>
      InspectorException(
        ErrorCodes.invalidRequest,
        'SharedPreferences can only store bool, int, double, String or a list '
        'of strings, not ${InMemoryQuery.typeName(value)}',
      );
}

/// The operations each SharedPreferences API provides.
sealed class _Backend {
  Future<void> refresh() async {}

  Iterable<String> get keys;

  bool contains(String key);

  Object? get(String key);

  Future<void> setBool(String key, bool value);

  Future<void> setInt(String key, int value);

  Future<void> setDouble(String key, double value);

  Future<void> setString(String key, String value);

  Future<void> setStringList(String key, List<String> value);

  Future<void> remove(String key);

  Future<void> clear();
}

final class _LegacyBackend extends _Backend {
  _LegacyBackend(this.prefs);

  final SharedPreferences prefs;

  @override
  Iterable<String> get keys => prefs.getKeys();

  @override
  bool contains(String key) => prefs.containsKey(key);

  @override
  Object? get(String key) => prefs.get(key);

  @override
  Future<void> setBool(String key, bool value) =>
      _check(prefs.setBool(key, value));

  @override
  Future<void> setInt(String key, int value) =>
      _check(prefs.setInt(key, value));

  @override
  Future<void> setDouble(String key, double value) =>
      _check(prefs.setDouble(key, value));

  @override
  Future<void> setString(String key, String value) =>
      _check(prefs.setString(key, value));

  @override
  Future<void> setStringList(String key, List<String> value) =>
      _check(prefs.setStringList(key, value));

  @override
  Future<void> remove(String key) => _check(prefs.remove(key));

  @override
  Future<void> clear() => _check(prefs.clear());

  static Future<void> _check(Future<bool> write) async {
    if (!await write) {
      throw InspectorException(
        ErrorCodes.queryFailed,
        'The platform failed to persist the SharedPreferences change',
      );
    }
  }
}

final class _CachedBackend extends _Backend {
  _CachedBackend(this.prefs);

  final SharedPreferencesWithCache prefs;

  @override
  Iterable<String> get keys => prefs.keys;

  @override
  bool contains(String key) {
    try {
      return prefs.containsKey(key);
    } on ArgumentError {
      return false; // Outside the allow list.
    }
  }

  @override
  Object? get(String key) => contains(key) ? prefs.get(key) : null;

  @override
  Future<void> setBool(String key, bool value) => prefs.setBool(key, value);

  @override
  Future<void> setInt(String key, int value) => prefs.setInt(key, value);

  @override
  Future<void> setDouble(String key, double value) =>
      prefs.setDouble(key, value);

  @override
  Future<void> setString(String key, String value) =>
      prefs.setString(key, value);

  @override
  Future<void> setStringList(String key, List<String> value) =>
      prefs.setStringList(key, value);

  @override
  Future<void> remove(String key) => prefs.remove(key);

  @override
  Future<void> clear() => prefs.clear();
}

final class _AsyncBackend extends _Backend {
  _AsyncBackend(this.prefs, this.allowList);

  final SharedPreferencesAsync prefs;
  final Set<String>? allowList;

  /// Snapshot of the platform data, reloaded by [refresh] and kept in sync
  /// with writes made through this store.
  Map<String, Object?> _snapshot = const {};

  @override
  Future<void> refresh() async {
    _snapshot = Map.of(await prefs.getAll(allowList: allowList));
  }

  @override
  Iterable<String> get keys => _snapshot.keys;

  @override
  bool contains(String key) => _snapshot.containsKey(key);

  @override
  Object? get(String key) => _snapshot[key];

  void _checkAllowed(String key) {
    final allowList = this.allowList;
    if (allowList != null && !allowList.contains(key)) {
      throw ArgumentError('$key is not included in the allow list');
    }
  }

  Future<void> _write(String key, Object value, Future<void> write) async {
    await write;
    _snapshot = {..._snapshot, key: value};
  }

  @override
  Future<void> setBool(String key, bool value) {
    _checkAllowed(key);
    return _write(key, value, prefs.setBool(key, value));
  }

  @override
  Future<void> setInt(String key, int value) {
    _checkAllowed(key);
    return _write(key, value, prefs.setInt(key, value));
  }

  @override
  Future<void> setDouble(String key, double value) {
    _checkAllowed(key);
    return _write(key, value, prefs.setDouble(key, value));
  }

  @override
  Future<void> setString(String key, String value) {
    _checkAllowed(key);
    return _write(key, value, prefs.setString(key, value));
  }

  @override
  Future<void> setStringList(String key, List<String> value) {
    _checkAllowed(key);
    return _write(key, value, prefs.setStringList(key, value));
  }

  @override
  Future<void> remove(String key) async {
    await prefs.remove(key);
    _snapshot = {..._snapshot}..remove(key);
  }

  @override
  Future<void> clear() async {
    // Only clear what this store can see.
    await prefs.clear(allowList: allowList ?? _snapshot.keys.toSet());
    _snapshot = const {};
  }
}

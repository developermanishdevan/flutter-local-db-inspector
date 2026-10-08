import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:hive_ce/hive_ce.dart';

/// Converts a JSON-like value received from a client into the value written
/// to a Hive box. [previous] is the current value for updates and `null` for
/// inserts.
///
/// Use it to rebuild custom (TypeAdapter) objects, e.g.
/// `(json, previous) => previous is Person ? Person.fromJson(json! as Map) : json`.
typedef HiveDecode = Object? Function(Object? json, Object? previous);

/// [KeyValueStore] binding for a Hive [Box] or [LazyBox].
///
/// Values of a lazy box are read from disk on demand, page by page.
///
/// Custom objects (stored through a `TypeAdapter`) are displayed through
/// their `toJson()` when they have one. They are never overwritten with plain
/// JSON unless a [decode] callback is provided, because that would silently
/// change the stored type and break the app reading the box.
final class HiveBoxStore extends KeyValueStore {
  HiveBoxStore(this.box, {this.decode});

  /// The wrapped box. Must be open while it is inspected.
  final BoxBase<Object?> box;

  /// Optional conversion of client values before they are written.
  final HiveDecode? decode;

  @override
  String get name => box.name;

  @override
  int get length => box.length;

  @override
  Iterable<Object> get keys => box.keys.cast<Object>();

  @override
  bool containsKey(Object key) => box.containsKey(key);

  @override
  FutureOr<Object?> get(Object key) => switch (box) {
        final LazyBox<Object?> lazy => lazy.get(key),
        final Box<Object?> eager => eager.get(key),
        _ => throw StateError('Unsupported box type ${box.runtimeType}'),
      };

  @override
  Future<void> put(Object key, Object? value) async {
    try {
      await box.put(key, value);
    } on TypeError {
      // Typed boxes (e.g. `Box<int>`) reject values of another type.
      throw InspectorException(
        ErrorCodes.invalidRequest,
        'Box "$name" cannot store a value of type '
        '${InMemoryQuery.typeName(value)}',
      );
    }
  }

  @override
  Future<void> delete(Object key) => box.delete(key);

  @override
  Future<int> clear() => box.clear();

  @override
  Object? decodeForWrite(Object? value, {Object? previous}) {
    final decode = this.decode;
    if (decode != null) return decode(value, previous);
    if (!isJsonNative(previous)) {
      throw InspectorException(
        ErrorCodes.unsupportedOperation,
        'The current value in box "$name" is a custom object '
        '(${previous.runtimeType}) stored through a TypeAdapter. Writing plain '
        'JSON over it would change its type; pass a `decode` callback to '
        'HiveBoxStore/HiveAdapter to rebuild the object from JSON.',
      );
    }
    return value;
  }

  /// Whether [value] is made only of types Hive stores without a custom
  /// TypeAdapter and the inspector can round-trip as JSON.
  static bool isJsonNative(Object? value) => switch (value) {
        null ||
        bool() ||
        num() ||
        String() ||
        DateTime() ||
        Uint8List() =>
          true,
        List() => value.every(isJsonNative),
        Map() => value.entries
            .every((e) => isJsonNative(e.key) && isJsonNative(e.value)),
        _ => false,
      };
}

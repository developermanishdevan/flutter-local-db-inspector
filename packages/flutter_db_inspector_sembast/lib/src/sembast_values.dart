import 'dart:typed_data';

import 'package:sembast/blob.dart';
import 'package:sembast/timestamp.dart';

/// Conversions between Sembast's storage types and the inspector's raw
/// values.
///
/// Sembast stores JSON values plus its own [Timestamp] and [Blob]; the
/// inspector works with [DateTime] and [Uint8List].
abstract final class SembastValues {
  /// Sembast value → inspector value (plain, mutable collections).
  static Object? read(Object? value) => switch (value) {
        Timestamp() => value.toDateTime(isUtc: true),
        Blob() => value.bytes,
        Map() => <String, Object?>{
            for (final e in value.entries) '${e.key}': read(e.value),
          },
        List() => [for (final v in value) read(v)],
        _ => value,
      };

  /// Inspector value → value Sembast can store.
  static Object? write(Object? value) => switch (value) {
        DateTime() => Timestamp.fromDateTime(value),
        Uint8List() => Blob(value),
        Map() => <String, Object?>{
            for (final e in value.entries) '${e.key}': write(e.value),
          },
        List() => [for (final v in value) write(v)],
        _ => value,
      };
}

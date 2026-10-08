import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

/// Lenient, typed reads from a decoded JSON response object. Missing
/// required fields and wrong types throw [FormatException]; the client turns
/// those into `MALFORMED_RESPONSE` errors.
extension type const ResponseReader(JsonMap json) {
  static ResponseReader of(Object? value, String what) {
    if (value is Map<String, Object?>) return ResponseReader(value);
    if (value is Map) return ResponseReader(value.cast<String, Object?>());
    throw FormatException('$what must be a JSON object');
  }

  JsonMap map(String key) => switch (json[key]) {
        null => throw FormatException('Missing "$key"'),
        final Object value => ResponseReader.of(value, key).json,
      };

  JsonMap? optMap(String key) =>
      json[key] == null ? null : ResponseReader.of(json[key], key).json;

  String? optString(String key) => switch (json[key]) {
        null => null,
        final String s => s,
        _ => throw FormatException('"$key" must be a string'),
      };

  int? optInt(String key) => switch (json[key]) {
        null => null,
        final num n => n.toInt(),
        _ => throw FormatException('"$key" must be a number'),
      };

  bool boolean(String key, {bool fallback = false}) => switch (json[key]) {
        final bool b => b,
        _ => fallback,
      };

  List<Object?> list(String key) => switch (json[key]) {
        null => const [],
        final List<Object?> l => l,
        _ => throw FormatException('"$key" must be a list'),
      };

  List<String> strings(String key) => [
        for (final item in list(key))
          if (item is String)
            item
          else
            throw FormatException('"$key" must contain strings'),
      ];

  List<T> objects<T>(String key, T Function(JsonMap) parse) => [
        for (final item in list(key)) parse(ResponseReader.of(item, key).json),
      ];
}

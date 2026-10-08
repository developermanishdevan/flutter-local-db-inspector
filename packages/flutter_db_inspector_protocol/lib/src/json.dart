import 'errors.dart';

/// A decoded JSON object.
typedef JsonMap = Map<String, Object?>;

/// Strict, typed reads from a decoded JSON object.
///
/// Every failure surfaces as an [InspectorException] with
/// [ErrorCodes.invalidRequest] so malformed input never escapes as a raw
/// `TypeError`.
extension type const JsonReader(JsonMap json) {
  static JsonReader of(Object? value, String what) {
    if (value is Map<String, Object?>) return JsonReader(value);
    if (value is Map) return JsonReader(value.cast<String, Object?>());
    throw _invalid('$what must be a JSON object');
  }

  bool has(String key) => json[key] != null;

  T _req<T extends Object>(String key) {
    final value = json[key];
    if (value is T) return value;
    if (value == null) throw _invalid('Missing required field "$key"');
    throw _invalid('Field "$key" must be of type $T');
  }

  T? _opt<T extends Object>(String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is T) return value;
    throw _invalid('Field "$key" must be of type $T');
  }

  String string(String key) => _req<String>(key);
  String? optString(String key) => _opt<String>(key);
  bool boolean(String key, {bool fallback = false}) =>
      _opt<bool>(key) ?? fallback;
  int integer(String key) => _req<num>(key).toInt();
  int? optInt(String key) => _opt<num>(key)?.toInt();
  JsonMap map(String key) => JsonReader.of(_req<Object>(key), key).json;
  JsonMap? optMap(String key) =>
      json[key] == null ? null : JsonReader.of(json[key], key).json;

  List<Object?> list(String key) => _opt<List<Object?>>(key) ?? const [];

  List<String> strings(String key) => [
        for (final item in list(key))
          if (item is String)
            item
          else
            throw _invalid('"$key" must be strings'),
      ];

  List<T> objects<T>(String key, T Function(JsonMap) parse) => [
        for (final item in list(key)) parse(JsonReader.of(item, key).json),
      ];
}

InspectorException _invalid(String message) =>
    InspectorException(ErrorCodes.invalidRequest, message);

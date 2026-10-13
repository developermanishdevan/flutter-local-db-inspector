import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// Normalized value types so every engine renders through the same UI.
enum DbValueType {
  nullValue('null'),
  integer('integer'),
  real('real'),
  text('text'),
  boolean('boolean'),
  blob('blob'),
  dateTime('dateTime'),
  json('json'),
  unknown('unknown');

  const DbValueType(this.wireName);

  final String wireName;

  static DbValueType fromWire(String? name) => values.firstWhere(
        (t) => t.wireName == name,
        orElse: () => DbValueType.unknown,
      );
}

/// Sentinel the runtime substitutes for sensitive values.
final class MaskedValue {
  const MaskedValue();
}

/// A value an adapter could only partially read (e.g. a large text or blob
/// column). [preview] is a `String` or `Uint8List`; [totalBytes] is the size of
/// the full value.
final class TruncatedValue {
  const TruncatedValue(this.preview, this.totalBytes);

  final Object preview;
  final int totalBytes;
}

/// Limits applied when encoding values for a response.
final class ValueEncodingOptions {
  const ValueEncodingOptions({
    this.textPreviewBytes = 10 * 1024,
    this.blobPreviewBytes = 48,
  });

  /// Strings longer than this (UTF-8 bytes) are truncated.
  final int textPreviewBytes;

  /// Number of leading blob bytes included as a preview.
  final int blobPreviewBytes;

  /// Used when a response would otherwise exceed the size budget.
  static const compact = ValueEncodingOptions(
    textPreviewBytes: 256,
    blobPreviewBytes: 0,
  );
}

/// Encodes raw Dart values into protocol JSON values and back.
///
/// Plain JSON primitives are used where they are lossless. Everything else is
/// a tagged object `{"$type": ...}`:
///
/// | Raw value                    | Wire                                                     |
/// |------------------------------|----------------------------------------------------------|
/// | `null`, `bool`, `String`     | as is                                                    |
/// | `int` (JS-safe range)        | number                                                   |
/// | `int` (outside JS-safe)      | `{"$type":"bigint","value":"…"}`                         |
/// | `double` (finite)            | number                                                   |
/// | `double` (NaN/∞)             | `{"$type":"real","value":"NaN"}`                         |
/// | long `String`                | `{"$type":"text","preview":"…","size":n,"truncated":true}` |
/// | `Uint8List`                  | `{"$type":"blob","size":n,"preview":"<base64>","truncated":b}` |
/// | `DateTime`                   | `{"$type":"dateTime","value":"<ISO-8601>"}`              |
/// | `Map` / `List`               | `{"$type":"json","value":…}`                             |
/// | masked                       | `{"$type":"masked"}`                                     |
/// | anything else                | `{"$type":"unknown","display":"…"}`                      |
abstract final class DbValueCodec {
  static const typeKey = r'$type';
  static const maxSafeInteger = 9007199254740991;

  static Object? encode(
    Object? value, [
    ValueEncodingOptions options = const ValueEncodingOptions(),
  ]) {
    switch (value) {
      case null:
      case bool():
        return value;
      case int():
        return (value > maxSafeInteger || value < -maxSafeInteger)
            ? {typeKey: 'bigint', 'value': value.toString()}
            : value;
      case BigInt():
        return {typeKey: 'bigint', 'value': value.toString()};
      case double():
        return value.isFinite ? value : {typeKey: 'real', 'value': '$value'};
      case String():
        return _encodeText(value, null, options);
      case Uint8List():
        return _encodeBlob(value, value.length, options);
      case DateTime():
        return {typeKey: 'dateTime', 'value': value.toIso8601String()};
      case MaskedValue():
        return const {typeKey: 'masked'};
      case TruncatedValue(:final preview, :final totalBytes):
        return switch (preview) {
          String() => _encodeText(preview, totalBytes, options),
          Uint8List() => _encodeBlob(preview, totalBytes, options),
          _ => encode(preview, options),
        };
      case Map() || List():
        try {
          return {typeKey: 'json', 'value': jsonDecode(jsonEncode(value))};
        } on Object {
          return _unknown(value);
        }
      default:
        return _unknown(value);
    }
  }

  /// Decodes a wire value supplied by a client for a write or filter.
  static Object? decode(Object? wire) {
    if (wire is! Map) return wire;
    final type = wire[typeKey];
    final v = wire['value'];
    switch (type) {
      case 'bigint' when v is String:
        return int.tryParse(v) ?? (throw _bad('Invalid bigint "$v"'));
      case 'real' when v is String:
        return double.tryParse(v) ?? (throw _bad('Invalid real "$v"'));
      case 'dateTime' when v is String:
        return DateTime.tryParse(v) ?? (throw _bad('Invalid dateTime "$v"'));
      case 'blob' when wire['base64'] is String:
        return base64Decode(wire['base64'] as String);
      case 'json':
        return v;
      case 'masked':
      case 'text' || 'blob' when wire['truncated'] == true:
        throw _bad('Masked or truncated values cannot be written back');
      default:
        throw _bad('Unsupported value type "$type"');
    }
  }

  static Object _encodeText(
    String value,
    int? knownBytes,
    ValueEncodingOptions options,
  ) {
    final limit = options.textPreviewBytes;
    // Fast path: even at 3 bytes per UTF-16 unit the string is within budget.
    if (knownBytes == null && value.length * 3 <= limit) return value;
    final bytes = utf8.encode(value);
    final total = knownBytes ?? bytes.length;
    if (total <= limit && bytes.length == total) return value;
    var cut = bytes.length > limit ? limit : bytes.length;
    // Never split a multi-byte UTF-8 sequence.
    while (cut > 0 && cut < bytes.length && (bytes[cut] & 0xC0) == 0x80) {
      cut--;
    }
    return {
      typeKey: 'text',
      'preview': utf8.decode(bytes.sublist(0, cut)),
      'size': total,
      'truncated': true,
    };
  }

  static Object _encodeBlob(
    Uint8List bytes,
    int totalBytes,
    ValueEncodingOptions options,
  ) {
    final cut = bytes.length < options.blobPreviewBytes
        ? bytes.length
        : options.blobPreviewBytes;
    return {
      typeKey: 'blob',
      'size': totalBytes,
      'preview': base64Encode(bytes.sublist(0, cut)),
      'truncated': cut < totalBytes,
    };
  }

  static Object _unknown(Object value) {
    var display = value.toString();
    if (display.length > 1024) display = '${display.substring(0, 1024)}…';
    return {typeKey: 'unknown', 'display': display};
  }

  static InspectorException _bad(String message) =>
      InspectorException(ErrorCodes.invalidRequest, message);
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

/// A value exactly as it travels over the wire (see `docs/protocol.md`).
///
/// Clients keep wire values instead of decoding them to raw Dart values:
/// masked, truncated and binary values carry information (size, preview)
/// that must be displayed, and keys must be sent back unchanged.
sealed class WireValue {
  const WireValue();

  /// Parses a decoded JSON value. Unknown tags become [WireUnknown].
  factory WireValue.fromJson(Object? json) {
    switch (json) {
      case null:
        return const WireNull();
      case bool():
        return WireBool(json);
      case int():
        return WireInt(json);
      case double():
        return WireDouble(json);
      case String():
        return WireString(json);
      case Map():
        return _parseTagged(json.cast<String, Object?>());
      case List():
        // Not produced by the runtime; keep it lossless anyway.
        return WireJson(json);
      default:
        return WireUnknown(json.toString());
    }
  }

  static WireValue _parseTagged(JsonMap json) {
    final type = json[DbValueCodec.typeKey];
    String str(String key) => switch (json[key]) {
          final String s => s,
          final Object o => o.toString(),
          null => '',
        };
    int size() => switch (json['size']) {
          final num n => n.toInt(),
          _ => 0,
        };
    switch (type) {
      case 'bigint':
        return WireBigInt(str('value'));
      case 'real':
        return WireReal(str('value'));
      case 'text':
        return WireTruncatedText(
          preview: str('preview'),
          size: size(),
          truncated: json['truncated'] != false,
        );
      case 'blob':
        final base64 = json['base64'];
        return WireBlob(
          size: size(),
          previewBase64: str('preview'),
          truncated: json['truncated'] == true,
          base64: base64 is String ? base64 : null,
        );
      case 'dateTime':
        return WireDateTime(str('value'));
      case 'json':
        return WireJson(json['value']);
      case 'masked':
        return const WireMasked();
      case 'unknown':
        return WireUnknown(str('display'));
      default:
        // A tag from a newer runtime, or a plain JSON object.
        return type == null ? WireJson(json) : WireUnknown(jsonEncode(json));
    }
  }

  /// The JSON form sent back to the runtime.
  Object? toJson();

  /// True for previews of larger values (truncated text, partial blobs). The
  /// full value needs `value.read`.
  bool get isPartial => false;

  bool get isMasked => false;

  bool get isNull => false;

  @override
  bool operator ==(Object other) =>
      other is WireValue &&
      other.runtimeType == runtimeType &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => Object.hash(runtimeType, jsonEncode(toJson()));

  @override
  String toString() => jsonEncode(toJson());
}

final class WireNull extends WireValue {
  const WireNull();

  @override
  Object? toJson() => null;

  @override
  bool get isNull => true;
}

final class WireBool extends WireValue {
  const WireBool(this.value);

  final bool value;

  @override
  Object? toJson() => value;
}

/// An integer within the JavaScript-safe range.
final class WireInt extends WireValue {
  const WireInt(this.value);

  final int value;

  @override
  Object? toJson() => value;
}

/// A finite floating point number.
final class WireDouble extends WireValue {
  const WireDouble(this.value);

  final double value;

  @override
  Object? toJson() => value;
}

final class WireString extends WireValue {
  const WireString(this.value);

  final String value;

  @override
  Object? toJson() => value;
}

/// An integer outside the JavaScript-safe range, kept as exact decimal text.
final class WireBigInt extends WireValue {
  const WireBigInt(this.text);

  final String text;

  BigInt? get value => BigInt.tryParse(text);

  @override
  Object? toJson() => {DbValueCodec.typeKey: 'bigint', 'value': text};
}

/// A non-finite double (`NaN`, `Infinity`, `-Infinity`).
final class WireReal extends WireValue {
  const WireReal(this.text);

  final String text;

  @override
  Object? toJson() => {DbValueCodec.typeKey: 'real', 'value': text};
}

/// A long text value of which only [preview] was sent.
final class WireTruncatedText extends WireValue {
  const WireTruncatedText({
    required this.preview,
    required this.size,
    this.truncated = true,
  });

  final String preview;

  /// Size of the full value in UTF-8 bytes.
  final int size;
  final bool truncated;

  @override
  bool get isPartial => truncated;

  @override
  Object? toJson() => {
        DbValueCodec.typeKey: 'text',
        'preview': preview,
        'size': size,
        'truncated': truncated,
      };
}

/// Binary data. Reads carry a short [previewBase64]; writes carry [base64].
final class WireBlob extends WireValue {
  const WireBlob({
    required this.size,
    this.previewBase64 = '',
    this.truncated = false,
    this.base64,
  });

  /// A blob to write.
  factory WireBlob.bytes(Uint8List bytes) =>
      WireBlob(size: bytes.length, base64: base64Encode(bytes));

  final int size;
  final String previewBase64;
  final bool truncated;

  /// The complete value (only for values built by the client).
  final String? base64;

  Uint8List get previewBytes => _decodeBase64(previewBase64);

  @override
  bool get isPartial => truncated;

  @override
  Object? toJson() => base64 != null
      ? {DbValueCodec.typeKey: 'blob', 'base64': base64}
      : {
          DbValueCodec.typeKey: 'blob',
          'size': size,
          'preview': previewBase64,
          'truncated': truncated,
        };
}

final class WireDateTime extends WireValue {
  const WireDateTime(this.text);

  /// ISO-8601 text as sent by the runtime.
  final String text;

  DateTime? get value => DateTime.tryParse(text);

  @override
  Object? toJson() => {DbValueCodec.typeKey: 'dateTime', 'value': text};
}

/// A map or list (document and key-value stores).
final class WireJson extends WireValue {
  const WireJson(this.value);

  final Object? value;

  @override
  Object? toJson() => {DbValueCodec.typeKey: 'json', 'value': value};
}

/// A sensitive value the app never sends.
final class WireMasked extends WireValue {
  const WireMasked();

  @override
  bool get isMasked => true;

  @override
  Object? toJson() => const {DbValueCodec.typeKey: 'masked'};
}

/// A value without a JSON form; [display] is its `toString()`.
final class WireUnknown extends WireValue {
  const WireUnknown(this.display);

  final String display;

  @override
  Object? toJson() => {DbValueCodec.typeKey: 'unknown', 'display': display};
}

Uint8List _decodeBase64(String text) {
  if (text.isEmpty) return Uint8List(0);
  try {
    return base64Decode(text);
  } on FormatException {
    return Uint8List(0);
  }
}

/// Visual category of a rendered cell, so UIs can style it.
enum CellKind {
  nullValue,
  boolean,
  number,
  text,
  date,
  masked,
  partial,
  blob,
  json,
  unknown,
}

/// How a value is shown in a grid cell.
final class CellDisplay {
  const CellDisplay(this.text, this.kind, {this.tooltip});

  final String text;
  final CellKind kind;
  final String? tooltip;

  @override
  String toString() => 'CellDisplay($text, $kind)';
}

/// Rendering, editing and parsing rules shared by every Dart client. A port
/// of `src/protocol/values.ts` from the VS Code extension.
abstract final class WireValues {
  /// Longest text rendered in a single grid cell.
  static const maxCellChars = 300;

  static const maskedText = '••••••••';

  /// How [value] is rendered in a grid cell.
  static CellDisplay display(WireValue value) {
    String clip(String text) => text.length > maxCellChars
        ? '${text.substring(0, maxCellChars)}…'
        : text;
    return switch (value) {
      WireNull() => const CellDisplay('NULL', CellKind.nullValue),
      WireBool(:final value) => CellDisplay('$value', CellKind.boolean),
      WireInt(:final value) => CellDisplay('$value', CellKind.number),
      WireDouble(:final value) =>
        CellDisplay(formatDouble(value), CellKind.number),
      WireString(:final value) => value.length > maxCellChars
          ? CellDisplay(
              clip(value),
              CellKind.text,
              tooltip: '${value.length} characters',
            )
          : CellDisplay(value, CellKind.text),
      WireBigInt(:final text) ||
      WireReal(:final text) =>
        CellDisplay(text, CellKind.number),
      WireDateTime(:final text) => CellDisplay(text, CellKind.date),
      WireMasked() => const CellDisplay(
          maskedText,
          CellKind.masked,
          tooltip: 'Sensitive value (masked by the app)',
        ),
      WireTruncatedText(:final preview, :final size) => CellDisplay(
          '${preview.length > maxCellChars ? preview.substring(0, maxCellChars) : preview}…',
          CellKind.partial,
          tooltip: 'Text, ${formatBytes(size)} (preview)',
        ),
      WireBlob(:final size) =>
        CellDisplay('BLOB ${formatBytes(size)}', CellKind.blob),
      WireJson(:final value) =>
        CellDisplay(clip(encodeJson(value)), CellKind.json),
      WireUnknown(:final display) => CellDisplay(
          display,
          CellKind.unknown,
          tooltip: 'Value has no JSON representation',
        ),
    };
  }

  /// Formats a finite double the same way on the VM and on the web
  /// (`2.0` → `2`).
  static String formatDouble(double value) =>
      value == value.truncateToDouble() && value.abs() < 1e15
          ? value.toInt().toString()
          : value.toString();

  /// Whether a cell can be edited inline without loss.
  static bool isInlineEditable(WireValue value) => switch (value) {
        WireNull() ||
        WireBool() ||
        WireInt() ||
        WireDouble() ||
        WireString() ||
        WireBigInt() ||
        WireDateTime() ||
        WireJson() =>
          true,
        _ => false,
      };

  /// Text shown when editing a value.
  static String editText(WireValue value) => switch (value) {
        WireNull() => '',
        WireBool(:final value) => '$value',
        WireInt(:final value) => '$value',
        WireDouble(:final value) => formatDouble(value),
        WireString(:final value) => value,
        WireBigInt(:final text) ||
        WireReal(:final text) ||
        WireDateTime(:final text) =>
          text,
        WireJson(:final value) => encodeJson(value, indent: '  '),
        WireTruncatedText(:final preview) => preview,
        WireUnknown(:final display) => display,
        WireMasked() || WireBlob() => '',
      };

  static final _integer = RegExp(r'^-?\d+$');
  static final _true = RegExp(r'^(true|1)$', caseSensitive: false);
  static final _false = RegExp(r'^(false|0)$', caseSensitive: false);

  /// Converts user input into a wire value according to the column [type].
  ///
  /// Input that does not fit the type is kept as text: SQLite and most
  /// document stores accept it, and the engine reports a clear error
  /// otherwise.
  static WireValue parseInput(String text, DbValueType type) {
    final trimmed = text.trim();
    switch (type) {
      case DbValueType.integer:
        if (_integer.hasMatch(trimmed)) return _integerValue(trimmed);
        return WireString(text);
      case DbValueType.real:
        final n = trimmed.isEmpty ? null : double.tryParse(trimmed);
        if (n == null || !n.isFinite) return WireString(text);
        // Keep integral input integral so `5` stays `5`, not `5.0`.
        return _integer.hasMatch(trimmed)
            ? _integerValue(trimmed)
            : WireDouble(n);
      case DbValueType.boolean:
        if (_true.hasMatch(trimmed)) return const WireBool(true);
        if (_false.hasMatch(trimmed)) return const WireBool(false);
        return WireString(text);
      case DbValueType.text:
      case DbValueType.dateTime:
        return WireString(text);
      case DbValueType.nullValue:
      case DbValueType.blob:
      case DbValueType.json:
      case DbValueType.unknown:
        return parseLoose(text);
    }
  }

  /// For untyped and JSON columns: JSON when it parses, otherwise text.
  static WireValue parseLoose(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return WireString(text);
    if (_integer.hasMatch(trimmed)) return _integerValue(trimmed);
    final Object? parsed;
    try {
      parsed = jsonDecode(trimmed);
    } on FormatException {
      return WireString(text);
    }
    return switch (parsed) {
      null => const WireNull(),
      final bool b => WireBool(b),
      final String s => WireString(s),
      final int i => WireInt(i),
      final double d => WireDouble(d),
      _ => WireJson(parsed),
    };
  }

  static WireValue _integerValue(String digits) {
    final big = BigInt.parse(digits);
    final safe = BigInt.from(DbValueCodec.maxSafeInteger);
    return big.abs() <= safe ? WireInt(big.toInt()) : WireBigInt(digits);
  }

  /// Converts a wire value into a raw Dart value for protocol models that
  /// take raw values (e.g. `RowFilter.value`). Large integers become
  /// [BigInt] so they stay exact on the web.
  static Object? toRaw(WireValue value) => switch (value) {
        WireNull() => null,
        WireBool(:final value) => value,
        WireInt(:final value) => value,
        WireDouble(:final value) => value,
        WireString(:final value) => value,
        WireBigInt(:final text) => BigInt.tryParse(text) ?? text,
        WireReal(:final text) => double.tryParse(text) ?? text,
        WireDateTime(:final text) => DateTime.tryParse(text) ?? text,
        WireJson(:final value) => value,
        WireTruncatedText(:final preview) => preview,
        WireBlob(:final base64) =>
          base64 == null ? null : _decodeBase64(base64),
        WireMasked() => null,
        WireUnknown(:final display) => display,
      };

  /// Plain JSON-compatible value for copy/export. Large integers become
  /// [RawJsonNumber] so [encodeJson] writes them exactly.
  static Object? toPlain(WireValue value) => switch (value) {
        WireNull() || WireMasked() => null,
        WireBool(:final value) => value,
        WireInt(:final value) => value,
        WireDouble(:final value) => value,
        WireString(:final value) => value,
        WireBigInt(:final text) => RawJsonNumber(text),
        // NaN / Infinity have no JSON form.
        WireReal(:final text) => text,
        WireDateTime(:final text) => text,
        WireJson(:final value) => value,
        WireTruncatedText(:final preview) => preview,
        WireBlob(:final base64) => base64,
        WireUnknown(:final display) => display,
      };

  /// Text copied for a single cell.
  static String copyText(WireValue value) {
    final plain = toPlain(value);
    return switch (plain) {
      null => '',
      RawJsonNumber(:final text) => text,
      Map() || List() => encodeJson(plain, indent: '  '),
      _ => '$plain',
    };
  }

  /// A row as a JSON object (exact big integers).
  static Map<String, Object?> rowToObject(
    List<String> columns,
    List<WireValue> values,
  ) =>
      {
        for (var i = 0; i < columns.length; i++)
          columns[i]: toPlain(i < values.length ? values[i] : const WireNull()),
      };

  static const _rawMarker = '__fdi_raw_number__:';
  static final _rawPattern = RegExp('"$_rawMarker(-?\\d+)"');

  /// `jsonEncode` that writes [RawJsonNumber]s unquoted.
  static String encodeJson(Object? value, {String? indent}) {
    Object? toEncodable(Object? v) =>
        v is RawJsonNumber ? '$_rawMarker${v.text}' : v.toString();
    final encoder = indent == null
        ? JsonEncoder(toEncodable)
        : JsonEncoder.withIndent(indent, toEncodable);
    return encoder
        .convert(value)
        .replaceAllMapped(_rawPattern, (m) => m.group(1)!);
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
  }

  /// `1234567` → `1,234,567`.
  static String formatCount(int? n) {
    if (n == null) return '';
    final digits = n.abs().toString();
    final out = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  /// Classic 16-bytes-per-line hex dump.
  static String hexDump(List<int> bytes, {int startOffset = 0}) {
    if (bytes.isEmpty) return '(no preview)';
    final lines = <String>[];
    for (var offset = 0; offset < bytes.length; offset += 16) {
      final end = offset + 16 > bytes.length ? bytes.length : offset + 16;
      final slice = bytes.sublist(offset, end);
      final hex =
          slice.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      final ascii = String.fromCharCodes(
        slice.map((b) => b >= 32 && b < 127 ? b : 0x2e),
      );
      lines.add(
        '${(startOffset + offset).toRadixString(16).padLeft(8, '0')}  '
        '${hex.padRight(47)}  $ascii',
      );
    }
    return lines.join('\n');
  }
}

/// A JSON number that must be written verbatim (e.g. a 64-bit integer).
final class RawJsonNumber {
  const RawJsonNumber(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      other is RawJsonNumber && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => text;
}

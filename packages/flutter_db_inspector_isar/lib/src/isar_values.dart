import 'dart:typed_data';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:isar_community/isar.dart';

/// Conversions between Isar's JSON export/import format and the inspector's
/// raw values, driven by the collection schema.
///
/// Isar exports `DateTime`s as microseconds since the epoch and byte lists as
/// int lists; the inspector shows them as date-times and bytes.
final class IsarValues {
  IsarValues(this.schema);

  final CollectionSchema<Object?> schema;

  /// Exported JSON object → inspector document.
  Map<String, Object?> read(Map<String, Object?> json) =>
      _readObject(json, schema);

  Map<String, Object?> _readObject(
    Map<String, Object?> json,
    Schema<Object?> owner,
  ) =>
      {
        for (final e in json.entries)
          e.key: switch (owner.properties[e.key]) {
            final PropertySchema p => _readValue(e.value, p.type, p.target),
            null => e.value, // the id
          },
      };

  Object? _readValue(Object? value, IsarType type, String? target) {
    if (value == null) return null;
    switch (type) {
      case IsarType.dateTime when value is int:
        return DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true);
      case IsarType.byteList when value is List:
        return Uint8List.fromList(value.cast<int>());
      case IsarType.object when value is Map:
        return _readObject(value.cast<String, Object?>(), _embedded(target));
      case IsarType.dateTimeList || IsarType.objectList when value is List:
        return [
          for (final v in value) _readValue(v, type.scalarType, target),
        ];
      default:
        return value;
    }
  }

  /// Inspector values for [fields] → Isar JSON. Throws `COLUMN_NOT_FOUND` for
  /// unknown fields and `INVALID_REQUEST` for values of the wrong type.
  Map<String, Object?> write(Map<String, Object?> fields) =>
      _writeObject(fields, schema, schema.name);

  Map<String, Object?> _writeObject(
    Map<String, Object?> fields,
    Schema<Object?> owner,
    String path,
  ) {
    final json = <String, Object?>{};
    for (final e in fields.entries) {
      final property = owner.properties[e.key];
      if (property == null) {
        if (identical(owner, schema) && e.key == schema.idName) {
          // A null id lets Isar auto-increment.
          if (e.value != null) json[e.key] = _int(e.value, '$path.${e.key}');
          continue;
        }
        throw AdapterErrors.columnNotFound(path, e.key);
      }
      json[e.key] = _writeValue(
        e.value,
        property.type,
        property.target,
        '$path.${e.key}',
      );
    }
    return json;
  }

  Object? _writeValue(
    Object? value,
    IsarType type,
    String? target,
    String path,
  ) {
    if (value == null) return null;
    if (type.isList) {
      final list = value is Uint8List ? value.toList() : value;
      if (list is! List) throw _bad(path, 'a list', value);
      return [
        for (final v in list) _writeValue(v, type.scalarType, target, path),
      ];
    }
    switch (type) {
      case IsarType.bool:
        return switch (value) {
          bool() => value,
          'true' || 'TRUE' || 'True' => true,
          'false' || 'FALSE' || 'False' => false,
          _ => throw _bad(path, 'a bool', value),
        };
      case IsarType.byte || IsarType.int || IsarType.long:
        return _int(value, path);
      case IsarType.float || IsarType.double:
        return switch (value) {
          num() => value.toDouble(),
          String() =>
            double.tryParse(value) ?? (throw _bad(path, 'a number', value)),
          _ => throw _bad(path, 'a number', value),
        };
      case IsarType.dateTime:
        return switch (value) {
          DateTime() => value.microsecondsSinceEpoch,
          int() => value,
          String() => DateTime.tryParse(value)?.microsecondsSinceEpoch ??
              (throw _bad(path, 'a date-time', value)),
          _ => throw _bad(path, 'a date-time', value),
        };
      case IsarType.string:
        return switch (value) {
          String() => value,
          num() || bool() => '$value',
          _ => throw _bad(path, 'a string', value),
        };
      case IsarType.object:
        if (value is! Map) throw _bad(path, 'an object', value);
        return _writeObject(
          value.cast<String, Object?>(),
          _embedded(target),
          path,
        );
      default:
        throw _bad(path, type.schemaName, value);
    }
  }

  int _int(Object? value, String path) => switch (value) {
        int() => value,
        double() when value == value.truncateToDouble() => value.toInt(),
        String() =>
          int.tryParse(value) ?? (throw _bad(path, 'an integer', value)),
        _ => throw _bad(path, 'an integer', value),
      };

  Schema<Object?> _embedded(String? target) =>
      schema.embeddedSchemas[target] ??
      (throw StateError('Missing embedded schema "$target"'));

  static InspectorException _bad(String path, String expected, Object? value) =>
      InspectorException(
        ErrorCodes.invalidRequest,
        '"$path" expects $expected, got ${InMemoryQuery.typeName(value)}',
      );

  /// Normalized type of an Isar property.
  static DbValueType valueType(IsarType type) => switch (type) {
        IsarType.bool => DbValueType.boolean,
        IsarType.byte || IsarType.int || IsarType.long => DbValueType.integer,
        IsarType.float || IsarType.double => DbValueType.real,
        IsarType.dateTime => DbValueType.dateTime,
        IsarType.string => DbValueType.text,
        IsarType.byteList => DbValueType.blob,
        _ => DbValueType.json,
      };
}

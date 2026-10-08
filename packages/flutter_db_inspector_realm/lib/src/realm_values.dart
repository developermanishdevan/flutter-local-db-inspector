import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:realm_dart/realm.dart';

/// Conversions between Realm property values and the JSON-like values the
/// inspector exchanges.
abstract final class RealmValues {
  /// Maximum nesting of embedded objects / mixed collections rendered inline.
  static const maxDepth = 6;

  /// Whether [p] holds a single primitive value (editable and natively
  /// filterable), as opposed to links, embedded objects and collections.
  static bool isPrimitive(SchemaProperty p) =>
      p.collectionType == RealmCollectionType.none &&
      p.propertyType != RealmPropertyType.object &&
      p.propertyType != RealmPropertyType.linkingObjects;

  static DbValueType valueType(SchemaProperty p) {
    if (!isPrimitive(p)) return DbValueType.json;
    return switch (p.propertyType) {
      RealmPropertyType.int => DbValueType.integer,
      RealmPropertyType.bool => DbValueType.boolean,
      RealmPropertyType.string ||
      RealmPropertyType.objectid ||
      RealmPropertyType.uuid =>
        DbValueType.text,
      RealmPropertyType.binary => DbValueType.blob,
      RealmPropertyType.timestamp => DbValueType.dateTime,
      RealmPropertyType.float ||
      RealmPropertyType.double ||
      RealmPropertyType.decimal128 =>
        DbValueType.real,
      _ => DbValueType.unknown, // mixed
    };
  }

  /// Engine type as declared in the schema, e.g. `string?`, `list<int>`,
  /// `link<Person>`, `map<string, double?>`.
  static String declaredType(SchemaProperty p) {
    final base = switch (p.propertyType) {
      RealmPropertyType.object => 'link<${p.linkTarget}>',
      RealmPropertyType.linkingObjects => 'backlinks<${p.linkTarget}>',
      RealmPropertyType.objectid => 'objectId',
      RealmPropertyType.timestamp => 'date',
      RealmPropertyType.binary => 'data',
      final t => t.name,
    };
    final element = p.optional && p.propertyType != RealmPropertyType.mixed
        ? '$base?'
        : base;
    return switch (p.collectionType) {
      RealmCollectionType.list => 'list<$element>',
      RealmCollectionType.set => 'set<$element>',
      RealmCollectionType.map => 'map<string, $element>',
      _ => element,
    };
  }

  /// Reads property [p] of [object] as an inspector value.
  static Object? read(RealmObjectBase object, SchemaProperty p,
      [int depth = 0]) {
    // The generic accessor returns RealmList/RealmSet/RealmMap/RealmObject or
    // a primitive; `Object?` asks Realm for untyped (dynamic-schema) access.
    final raw = RealmObjectBase.get<Object?>(object, p.name);
    return toDisplay(raw, depth);
  }

  /// Converts a raw Realm value into a JSON-like value.
  static Object? toDisplay(Object? value, [int depth = 0]) {
    switch (value) {
      case null || bool() || int() || String() || Uint8List() || DateTime():
        return value;
      case double():
        return value;
      case RealmValue():
        return toDisplay(value.value, depth);
      case ObjectId() || Uuid():
        return value.toString();
      case Decimal128():
        return double.tryParse(value.toString()) ?? value.toString();
      case RealmObjectBase():
        return _object(value, depth);
      case Map<String, Object?>():
        if (depth >= maxDepth) return '{…}';
        return {
          for (final e in value.entries) e.key: toDisplay(e.value, depth + 1),
        };
      case Iterable<Object?>():
        if (depth >= maxDepth) return '[…]';
        return [for (final v in value) toDisplay(v, depth + 1)];
      default:
        return value.toString();
    }
  }

  static Object? _object(RealmObjectBase object, int depth) {
    if (!object.isValid) return null;
    final schema = object.objectSchema;
    if (schema.baseType == ObjectType.embeddedObject) {
      if (depth >= maxDepth) return {r'$embedded': schema.name};
      return {
        for (final p in schema)
          if (p.propertyType != RealmPropertyType.linkingObjects)
            p.name: read(object, p, depth + 1),
      };
    }
    final pk = schema.primaryKey;
    if (pk != null) {
      return toDisplay(RealmObjectBase.get<Object?>(object, pk.name));
    }
    return {r'$link': schema.name};
  }

  /// Converts an inspector value into the Dart type Realm expects for
  /// primitive property [p]. Throws `INVALID_REQUEST` for unusable values.
  static Object? toRealm(String className, SchemaProperty p, Object? value) {
    if (!isPrimitive(p)) {
      throw InspectorException(
        ErrorCodes.unsupportedOperation,
        'Property "$className.${p.name}" (${declaredType(p)}) is a link, '
        'embedded object or collection; only primitive properties can be '
        'edited from the inspector.',
        {'table': className, 'column': p.name},
      );
    }
    if (value == null) {
      if (p.optional || p.propertyType == RealmPropertyType.mixed) {
        return p.propertyType == RealmPropertyType.mixed
            ? const RealmValue.nullValue()
            : null;
      }
      throw _invalid(className, p, value, 'the property is not optional');
    }
    final converted = switch (p.propertyType) {
      RealmPropertyType.int => switch (value) {
          int() => value,
          double() when value == value.truncateToDouble() => value.toInt(),
          String() => int.tryParse(value.trim()),
          _ => null,
        },
      RealmPropertyType.bool => switch (value) {
          bool() => value,
          String() => switch (value.trim().toLowerCase()) {
              'true' || '1' => true,
              'false' || '0' => false,
              _ => null,
            },
          int() when value == 0 || value == 1 => value == 1,
          _ => null,
        },
      RealmPropertyType.string => value is String ? value : null,
      RealmPropertyType.float || RealmPropertyType.double => switch (value) {
          num() => value.toDouble(),
          String() => double.tryParse(value.trim()),
          _ => null,
        },
      RealmPropertyType.decimal128 => switch (value) {
          int() => Decimal128.fromInt(value),
          num() || String() => Decimal128.tryParse('$value'.trim()),
          _ => null,
        },
      RealmPropertyType.timestamp => switch (value) {
          DateTime() => value,
          String() => DateTime.tryParse(value.trim()),
          int() => DateTime.fromMillisecondsSinceEpoch(value, isUtc: true),
          _ => null,
        },
      RealmPropertyType.binary => switch (value) {
          Uint8List() => value,
          List<Object?>() when value.every((b) => b is int) =>
            Uint8List.fromList(value.cast<int>()),
          String() => Uint8List.fromList(utf8.encode(value)),
          _ => null,
        },
      RealmPropertyType.objectid => switch (value) {
          ObjectId() => value,
          String() => _tryParse(() => ObjectId.fromHexString(value.trim())),
          _ => null,
        },
      RealmPropertyType.uuid => switch (value) {
          Uuid() => value,
          String() => _tryParse(() => Uuid.fromString(value.trim())),
          _ => null,
        },
      RealmPropertyType.mixed => switch (value) {
          bool() ||
          num() ||
          String() ||
          DateTime() ||
          Uint8List() =>
            RealmValue.from(value),
          _ => null,
        },
      _ => null,
    };
    if (converted == null) {
      throw _invalid(
          className, p, value, 'expected a ${declaredType(p)} value');
    }
    return converted;
  }

  static T? _tryParse<T>(T Function() parse) {
    try {
      return parse();
    } on Object {
      return null;
    }
  }

  static InspectorException _invalid(
    String className,
    SchemaProperty p,
    Object? value,
    String reason,
  ) =>
      InspectorException(
        ErrorCodes.invalidRequest,
        'Invalid value for "$className.${p.name}": $reason',
        {'table': className, 'column': p.name},
      );
}

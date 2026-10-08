import '../capability.dart';
import '../json.dart';
import 'schema.dart';

/// A registered database as seen by clients.
final class DatabaseDescriptor {
  const DatabaseDescriptor({
    required this.id,
    required this.name,
    required this.type,
    required this.capabilities,
    this.dataModel = DbDataModel.relational,
    this.readOnly = false,
    this.isolateId,
  });

  factory DatabaseDescriptor.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return DatabaseDescriptor(
      id: r.string('id'),
      name: r.string('name'),
      type: r.string('type'),
      capabilities: DbCapability.parseAll(r.strings('capabilities')),
      dataModel: DbDataModel.fromWire(r.optString('dataModel')),
      readOnly: r.boolean('readOnly'),
      isolateId: r.optString('isolateId'),
    );
  }

  final String id;
  final String name;

  /// Engine identifier, e.g. `sqlite`, `drift`, `hive`.
  final String type;
  final Set<DbCapability> capabilities;
  final DbDataModel dataModel;

  /// True when writes are disabled for this database (registration or mode).
  final bool readOnly;

  /// Reserved for multi-isolate support.
  final String? isolateId;

  JsonMap toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'capabilities': [for (final c in capabilities) c.wireName],
        'dataModel': dataModel.name,
        'readOnly': readOnly,
        if (isolateId != null) 'isolateId': isolateId,
      };
}

/// Engine metadata for `database.info`.
final class DatabaseMetadata {
  const DatabaseMetadata({
    required this.engine,
    this.engineVersion,
    this.path,
    this.sizeBytes,
    this.extra = const {},
  });

  factory DatabaseMetadata.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return DatabaseMetadata(
      engine: r.string('engine'),
      engineVersion: r.optString('engineVersion'),
      path: r.optString('path'),
      sizeBytes: r.optInt('sizeBytes'),
      extra: r.optMap('extra') ?? const {},
    );
  }

  final String engine;
  final String? engineVersion;
  final String? path;
  final int? sizeBytes;

  /// Engine specific key/values (JSON primitives only).
  final JsonMap extra;

  JsonMap toJson() => {
        'engine': engine,
        if (engineVersion != null) 'engineVersion': engineVersion,
        if (path != null) 'path': path,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        'extra': extra,
      };
}

/// Result of `database.stats`.
final class DatabaseStats {
  const DatabaseStats({
    required this.entities,
    this.sizeBytes,
    this.indexCount = 0,
    this.triggerCount = 0,
  });

  factory DatabaseStats.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return DatabaseStats(
      entities: r.objects('entities', EntitySummary.fromJson),
      sizeBytes: r.optInt('sizeBytes'),
      indexCount: r.optInt('indexCount') ?? 0,
      triggerCount: r.optInt('triggerCount') ?? 0,
    );
  }

  final List<EntitySummary> entities;
  final int? sizeBytes;
  final int indexCount;
  final int triggerCount;

  int get totalRows => entities.fold(0, (sum, e) => sum + (e.rowCount ?? 0));

  JsonMap toJson() => {
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        'entityCount': entities.length,
        'indexCount': indexCount,
        'triggerCount': triggerCount,
        'totalRows': totalRows,
        'entities': [for (final e in entities) e.toJson()],
      };
}

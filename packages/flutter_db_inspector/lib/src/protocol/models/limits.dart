import '../json.dart';

/// Inspector modes. [disabled] never registers the service extension.
enum InspectorMode {
  disabled,
  readOnly,
  fullAccess;

  static InspectorMode fromWire(String? name) => values.firstWhere(
        (m) => m.name == name,
        orElse: () => InspectorMode.readOnly,
      );
}

/// Safety limits protecting the running application.
final class InspectorLimits {
  const InspectorLimits({
    this.defaultPageSize = 50,
    this.maxPageSize = 100,
    this.maxSqlRows = 100,
    this.maxResponseBytes = 5 * 1024 * 1024,
    this.queryTimeout = const Duration(seconds: 5),
    this.textPreviewBytes = 10 * 1024,
    this.blobChunkBytes = 1024 * 1024,
  });

  factory InspectorLimits.fromJson(JsonMap json) {
    final r = JsonReader(json);
    const d = InspectorLimits();
    return InspectorLimits(
      defaultPageSize: r.optInt('defaultPageSize') ?? d.defaultPageSize,
      maxPageSize: r.optInt('maxPageSize') ?? d.maxPageSize,
      maxSqlRows: r.optInt('maxSqlRows') ?? d.maxSqlRows,
      maxResponseBytes: r.optInt('maxResponseBytes') ?? d.maxResponseBytes,
      queryTimeout: Duration(
        milliseconds:
            r.optInt('queryTimeoutMs') ?? d.queryTimeout.inMilliseconds,
      ),
      textPreviewBytes: r.optInt('textPreviewBytes') ?? d.textPreviewBytes,
      blobChunkBytes: r.optInt('blobChunkBytes') ?? d.blobChunkBytes,
    );
  }

  final int defaultPageSize;
  final int maxPageSize;
  final int maxSqlRows;
  final int maxResponseBytes;
  final Duration queryTimeout;
  final int textPreviewBytes;

  /// Largest chunk `value.read` returns at once.
  final int blobChunkBytes;

  JsonMap toJson() => {
        'defaultPageSize': defaultPageSize,
        'maxPageSize': maxPageSize,
        'maxSqlRows': maxSqlRows,
        'maxResponseBytes': maxResponseBytes,
        'queryTimeoutMs': queryTimeout.inMilliseconds,
        'textPreviewBytes': textPreviewBytes,
        'blobChunkBytes': blobChunkBytes,
      };
}

/// Result of `inspector.status`.
final class InspectorStatus {
  const InspectorStatus({
    required this.protocolVersion,
    required this.supportedVersions,
    required this.packageVersion,
    required this.mode,
    required this.methods,
    required this.limits,
  });

  factory InspectorStatus.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return InspectorStatus(
      protocolVersion: r.integer('protocolVersion'),
      supportedVersions: [
        for (final v in r.list('supportedVersions'))
          if (v is num) v.toInt(),
      ],
      packageVersion: r.optString('packageVersion') ?? 'unknown',
      mode: InspectorMode.fromWire(r.optString('mode')),
      methods: r.strings('methods'),
      limits: InspectorLimits.fromJson(r.optMap('limits') ?? const {}),
    );
  }

  final int protocolVersion;
  final List<int> supportedVersions;
  final String packageVersion;
  final InspectorMode mode;
  final List<String> methods;
  final InspectorLimits limits;

  JsonMap toJson() => {
        'protocolVersion': protocolVersion,
        'supportedVersions': supportedVersions,
        'packageVersion': packageVersion,
        'mode': mode.name,
        'methods': methods,
        'limits': limits.toJson(),
      };
}

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

/// Immutable runtime configuration.
final class InspectorConfig {
  const InspectorConfig({
    this.mode = InspectorMode.disabled,
    this.limits = const InspectorLimits(),
    this.sensitiveColumns = const {},
  });

  final InspectorMode mode;
  final InspectorLimits limits;

  /// Masked columns as `table.column`, or `*.column` for every table.
  final Set<String> sensitiveColumns;

  bool get writable => mode == InspectorMode.fullAccess;

  InspectorConfig copyWith({
    InspectorMode? mode,
    InspectorLimits? limits,
    Set<String>? sensitiveColumns,
  }) =>
      InspectorConfig(
        mode: mode ?? this.mode,
        limits: limits ?? this.limits,
        sensitiveColumns: sensitiveColumns ?? this.sensitiveColumns,
      );

  bool isSensitive(String table, String column) =>
      sensitiveColumns.contains('$table.$column') ||
      sensitiveColumns.contains('*.$column');

  /// For ad-hoc query results, where the source table is unknown, a column is
  /// masked when any rule names it.
  bool isSensitiveName(String column) =>
      sensitiveColumns.any((rule) => rule.endsWith('.$column'));
}

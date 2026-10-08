import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

/// Value helpers for engines that filter, sort and search in memory
/// (key/value and document stores without a native query engine).
abstract final class InMemoryQuery {
  /// Converts a stored value into something the protocol can encode.
  /// Custom objects are shown through their `toJson()` when available.
  static Object? displayValue(Object? value) {
    switch (value) {
      case null || bool() || num() || String() || Uint8List() || DateTime():
        return value;
      case List():
        return [for (final v in value) displayValue(v)];
      case Map():
        return {
          for (final e in value.entries) '${e.key}': displayValue(e.value),
        };
      default:
        try {
          // ignore: avoid_dynamic_calls
          return displayValue((value as dynamic).toJson() as Object?);
        } on NoSuchMethodError {
          return value;
        }
    }
  }

  static String typeName(Object? value) => switch (value) {
        null => 'null',
        bool() => 'bool',
        int() => 'int',
        double() => 'double',
        String() => 'String',
        Uint8List() => 'bytes',
        MaskedValue() => 'secret',
        List() => 'List',
        Map() => 'Map',
        _ => value.runtimeType.toString(),
      };

  static String searchText(Object? value) => switch (value) {
        null => '',
        String() => value.toLowerCase(),
        Map() || List() => _tryJson(value).toLowerCase(),
        _ => value.toString().toLowerCase(),
      };

  static String _tryJson(Object value) {
    try {
      return jsonEncode(value);
    } on Object {
      return value.toString();
    }
  }

  /// Total order across mixed types: null < bool < num < String < other.
  static int compareValues(Object? a, Object? b) {
    int rank(Object? v) => switch (v) {
          null => 0,
          bool() => 1,
          num() => 2,
          String() => 3,
          _ => 4,
        };
    final ra = rank(a), rb = rank(b);
    if (ra != rb) return ra.compareTo(rb);
    return switch ((a, b)) {
      (final bool x, final bool y) => (x ? 1 : 0).compareTo(y ? 1 : 0),
      (final num x, final num y) => x.compareTo(y),
      (final String x, final String y) => x.compareTo(y),
      _ => searchText(a).compareTo(searchText(b)),
    };
  }

  /// Evaluates a filter in memory, comparing numerically when both sides are
  /// numeric and textually otherwise.
  static bool matchesFilter(Object? value, RowFilter filter) {
    final target = filter.value;
    switch (filter.operator) {
      case FilterOperator.isNull:
        return value == null;
      case FilterOperator.isNotNull:
        return value != null;
      case FilterOperator.contains:
        return searchText(value).contains(searchText(target));
      case FilterOperator.startsWith:
        return searchText(value).startsWith(searchText(target));
      case FilterOperator.endsWith:
        return searchText(value).endsWith(searchText(target));
      case FilterOperator.equals:
        return _compareLoose(value, target) == 0;
      case FilterOperator.notEquals:
        return _compareLoose(value, target) != 0;
      case FilterOperator.greaterThan:
        final c = _compareOrdered(value, target);
        return c != null && c > 0;
      case FilterOperator.lessThan:
        final c = _compareOrdered(value, target);
        return c != null && c < 0;
      case FilterOperator.greaterOrEqual:
        final c = _compareOrdered(value, target);
        return c != null && c >= 0;
      case FilterOperator.lessOrEqual:
        final c = _compareOrdered(value, target);
        return c != null && c <= 0;
    }
  }

  /// Ordering comparison; `null` when the values are not comparable (e.g. a
  /// number against non-numeric text), so range filters never match them.
  static int? _compareOrdered(Object? value, Object? target) {
    if (value == null || target == null) return null;
    final targetNum = target is num ? target : num.tryParse('$target');
    if (targetNum != null) {
      // Numeric target: only numeric values (or numeric text) are comparable.
      final valueNum = value is num ? value : num.tryParse('$value');
      return valueNum?.compareTo(targetNum);
    }
    if (value is num) return null;
    return _compareLoose(value, target);
  }

  static int _compareLoose(Object? value, Object? target) {
    if (value == null || target == null) {
      return value == target ? 0 : (value == null ? -1 : 1);
    }
    final a = value is num ? value : num.tryParse('$value');
    final b = target is num ? target : num.tryParse('$target');
    if (a != null && b != null && (value is num || target is num)) {
      return a.compareTo(b);
    }
    if (value is bool) return '$value'.compareTo('$target'.toLowerCase());
    final text = value is String ? value : searchText(value);
    return text.compareTo('$target');
  }

  /// Whether a record passes the query's search and filters.
  /// [column] resolves a column name to its display value.
  static bool matches(
    RowsQuery query,
    Iterable<String> searchable,
    Object? Function(String column) column,
  ) {
    final search = query.search?.toLowerCase();
    if (search != null &&
        !searchable
            .where((c) => !query.searchExcludedColumns.contains(c))
            .any((c) => searchText(column(c)).contains(search))) {
      return false;
    }
    return query.filters.every((f) => matchesFilter(column(f.column), f));
  }

  /// Comparator implementing the query's sort order.
  static int Function(T, T) comparator<T>(
    List<RowSort> sort,
    Object? Function(T record, String column) column,
  ) =>
      (a, b) {
        for (final s in sort) {
          final c = compareValues(column(a, s.column), column(b, s.column));
          if (c != 0) return s.direction == SortDirection.asc ? c : -c;
        }
        return 0;
      };
}

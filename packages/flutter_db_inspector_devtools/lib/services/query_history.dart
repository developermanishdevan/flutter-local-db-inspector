import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'history_storage.dart';

/// One executed query.
@immutable
class QueryHistoryEntry {
  const QueryHistoryEntry({
    required this.sql,
    required this.databaseId,
    required this.at,
    this.succeeded = true,
  });

  static QueryHistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final sql = json['sql'];
    final db = json['databaseId'];
    final at = json['at'];
    if (sql is! String || db is! String || at is! int) return null;
    return QueryHistoryEntry(
      sql: sql,
      databaseId: db,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      succeeded: json['succeeded'] != false,
    );
  }

  final String sql;
  final String databaseId;
  final DateTime at;
  final bool succeeded;

  Map<String, Object?> toJson() => {
        'sql': sql,
        'databaseId': databaseId,
        'at': at.millisecondsSinceEpoch,
        'succeeded': succeeded,
      };
}

/// Client-side SQL history, newest first, de-duplicated per database.
class QueryHistory extends ChangeNotifier {
  QueryHistory({HistoryStorage? storage, this.maxEntries = 100})
      : _storage = storage ?? HistoryStorage() {
    _load();
  }

  final HistoryStorage _storage;
  final int maxEntries;
  final _entries = <QueryHistoryEntry>[];

  List<QueryHistoryEntry> get entries => List.unmodifiable(_entries);

  List<QueryHistoryEntry> forDatabase(String databaseId) => [
        for (final e in _entries)
          if (e.databaseId == databaseId) e
      ];

  void add(QueryHistoryEntry entry) {
    _entries
      ..removeWhere(
        (e) => e.databaseId == entry.databaseId && e.sql == entry.sql,
      )
      ..insert(0, entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    _save();
    notifyListeners();
  }

  void remove(QueryHistoryEntry entry) {
    if (_entries.remove(entry)) {
      _save();
      notifyListeners();
    }
  }

  void clear(String databaseId) {
    _entries.removeWhere((e) => e.databaseId == databaseId);
    _save();
    notifyListeners();
  }

  void _load() {
    final raw = _storage.read();
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        final entry = QueryHistoryEntry.fromJson(item);
        if (entry != null) _entries.add(entry);
      }
    } on FormatException {
      // Corrupt storage: start over.
    }
  }

  void _save() =>
      _storage.write(jsonEncode([for (final e in _entries) e.toJson()]));
}

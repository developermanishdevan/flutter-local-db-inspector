import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// One saved SQL query.
final class SavedQuery {
  const SavedQuery({
    required this.id,
    required this.name,
    required this.sql,
    required this.createdAt,
    this.databaseType,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String sql;

  /// Engine type the query was written for, e.g. `sqlite`.
  final String? databaseType;

  /// Epoch milliseconds.
  final int createdAt;
  final int? updatedAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'sql': sql,
        if (databaseType != null) 'databaseType': databaseType,
        'createdAt': createdAt,
        if (updatedAt != null) 'updatedAt': updatedAt,
      };

  /// `null` for anything that is not a saved query.
  static SavedQuery? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? id = json['id'], name = json['name'], sql = json['sql'];
    if (id is! String || name is! String || sql is! String) return null;
    final createdAt = json['createdAt'];
    final updatedAt = json['updatedAt'];
    final databaseType = json['databaseType'];
    return SavedQuery(
      id: id,
      name: name,
      sql: sql,
      databaseType: databaseType is String ? databaseType : null,
      createdAt: createdAt is num ? createdAt.toInt() : 0,
      updatedAt: updatedAt is num ? updatedAt.toInt() : null,
    );
  }
}

/// Saved queries of one app, keyed by its Dart package name.
final class SavedQueryGroup {
  const SavedQueryGroup(this.app, this.queries);

  final String app;
  final List<SavedQuery> queries;

  Map<String, Object?> toJson() => {
        'app': app,
        'queries': [for (final q in queries) q.toJson()],
      };
}

/// Where saved queries are kept: one JSON document
/// (`{"version":1,"apps":{"<app>":[…]}}`), possibly per app.
abstract interface class SavedQueryBackend {
  /// Short name for diagnostics.
  String get name;

  /// The document holding [app]'s queries; `null` when nothing was stored
  /// yet. Throws when this backend cannot serve [app].
  Future<String?> read(String app);

  /// Replaces the document holding [app]'s queries.
  Future<void> write(String app, String contents);
}

/// In-memory backend, used in tests and as the last resort.
class MemorySavedQueryBackend implements SavedQueryBackend {
  MemorySavedQueryBackend([this.contents]);

  String? contents;

  @override
  String get name => 'memory';

  @override
  Future<String?> read(String app) async => contents;

  @override
  Future<void> write(String app, String contents) async =>
      this.contents = contents;
}

/// Used when the VM does not tell the app's package name.
const unknownApp = '(unknown app)';

/// SQL saved queries, kept per app (its Dart package name) until the user
/// deletes them. A port of the VS Code extension's `QueryStore` saved-query
/// part.
///
/// [backends] are tried in order for every operation; one that throws
/// (no Dart Tooling Daemon, no project for the app, file errors) hands over
/// to the next, so the last one should not fail.
class SavedQueryStore {
  SavedQueryStore(
    this.backends, {
    int Function()? now,
    String Function()? newId,
    this.log,
  })  : assert(backends.isNotEmpty),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = newId ?? _randomId;

  /// Memory only (tests).
  SavedQueryStore.memory() : this([MemorySavedQueryBackend()]);

  final List<SavedQueryBackend> backends;
  final void Function(String message)? log;
  final int Function() _now;
  final String Function() _newId;

  /// Serializes operations so concurrent saves don't lose each other.
  Future<void> _queue = Future.value();

  /// Every app with saved queries, [current] first, then by name.
  Future<List<SavedQueryGroup>> list(String? current) =>
      _run(current ?? unknownApp, (_) => false, current);

  /// Saves [sql] as [name] for [app]. A query with the same name (ignoring
  /// case) is replaced, keeping its id, so saving again updates it. Answers
  /// like [list] with [app] as the current app.
  Future<List<SavedQueryGroup>> save(
    String app,
    String name,
    String sql, {
    String? databaseType,
  }) {
    final trimmed = name.trim();
    return _run(app, (byApp) {
      final now = _now();
      final list = byApp[app] ?? const [];
      final key = trimmed.toLowerCase();
      final existing =
          list.where((q) => q.name.toLowerCase() == key).firstOrNull;
      final query = existing == null
          ? SavedQuery(
              id: _newId(),
              name: trimmed,
              sql: sql.trim(),
              databaseType: databaseType,
              createdAt: now,
            )
          : SavedQuery(
              id: existing.id,
              name: trimmed,
              sql: sql.trim(),
              databaseType: databaseType ?? existing.databaseType,
              createdAt: existing.createdAt,
              updatedAt: now,
            );
      byApp[app] = [...list.where((q) => q.id != query.id), query]
        ..sort((a, b) => _compareNames(a.name, b.name));
      return true;
    }, app);
  }

  /// Deletes one saved query of [app]; answers like [list] with [current].
  Future<List<SavedQueryGroup>> delete(
    String app,
    String id, {
    String? current,
  }) =>
      _run(app, (byApp) {
        final list = byApp[app];
        if (list == null) return false;
        final next = list.where((q) => q.id != id).toList();
        if (next.length == list.length) return false;
        if (next.isEmpty) {
          byApp.remove(app);
        } else {
          byApp[app] = next;
        }
        return true;
      }, current);

  /// Reads [app]'s document from the first working backend, applies
  /// [change] (which returns whether to write) and answers the groups.
  Future<List<SavedQueryGroup>> _run(
    String app,
    bool Function(Map<String, List<SavedQuery>> byApp) change,
    String? current,
  ) {
    final result = _queue.then((_) async {
      Object? lastError;
      for (final backend in backends) {
        try {
          final byApp = _decode(await backend.read(app), backend);
          if (change(byApp)) await backend.write(app, _encode(byApp));
          return _groups(byApp, current);
        } on Object catch (e) {
          lastError = e;
          log?.call('Saved queries: ${backend.name} unavailable ($e)');
        }
      }
      throw StateError('Saved queries could not be stored: $lastError');
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Map<String, List<SavedQuery>> _decode(
    String? contents,
    SavedQueryBackend backend,
  ) {
    final byApp = <String, List<SavedQuery>>{};
    if (contents == null || contents.trim().isEmpty) return byApp;
    Object? json;
    try {
      json = jsonDecode(contents);
    } on FormatException {
      log?.call('Saved queries: ignoring malformed ${backend.name} data');
      return byApp;
    }
    final apps = json is Map ? json['apps'] : null;
    if (apps is! Map) return byApp;
    for (final MapEntry(:key, :value) in apps.entries) {
      if (key is! String || value is! List) continue;
      final queries = value.map(SavedQuery.fromJson).nonNulls.toList();
      if (queries.isNotEmpty) byApp[key] = queries;
    }
    return byApp;
  }

  static String _encode(Map<String, List<SavedQuery>> byApp) =>
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'apps': {
          for (final MapEntry(:key, :value) in byApp.entries)
            if (value.isNotEmpty) key: [for (final q in value) q.toJson()],
        },
      });

  static List<SavedQueryGroup> _groups(
    Map<String, List<SavedQuery>> byApp,
    String? current,
  ) =>
      [
        for (final MapEntry(:key, :value) in byApp.entries)
          if (value.isNotEmpty) SavedQueryGroup(key, value),
      ]..sort((a, b) {
          final first = (b.app == current ? 1 : 0) - (a.app == current ? 1 : 0);
          return first != 0 ? first : _compareNames(a.app, b.app);
        });

  static int _compareNames(String a, String b) {
    final folded = a.toLowerCase().compareTo(b.toLowerCase());
    return folded != 0 ? folded : a.compareTo(b);
  }

  static final _random = Random();

  static String _randomId() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-'
      '${_random.nextInt(1 << 30).toRadixString(36)}';
}

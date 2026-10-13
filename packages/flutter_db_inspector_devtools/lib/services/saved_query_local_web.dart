import 'package:web/web.dart' as web;

import 'saved_query_store.dart';

SavedQueryBackend createLocalSavedQueryBackend() => _LocalStorage();

/// `window.localStorage`; falls back to memory when storage is blocked
/// (e.g. third-party iframe storage disabled).
class _LocalStorage implements SavedQueryBackend {
  static const _key = 'flutter_db_inspector.savedQueries.v1';
  final _fallback = MemorySavedQueryBackend();

  @override
  String get name => 'localStorage';

  @override
  Future<String?> read(String app) async {
    try {
      return web.window.localStorage.getItem(_key);
    } on Object {
      return _fallback.read(app);
    }
  }

  @override
  Future<void> write(String app, String contents) async {
    try {
      web.window.localStorage.setItem(_key, contents);
    } on Object {
      await _fallback.write(app, contents);
    }
  }
}

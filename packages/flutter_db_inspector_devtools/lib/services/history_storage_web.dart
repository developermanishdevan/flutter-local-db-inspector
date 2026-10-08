import 'package:web/web.dart' as web;

import 'history_storage.dart';

HistoryStorage createHistoryStorage() => _LocalStorage();

/// `window.localStorage`; falls back to memory when storage is blocked
/// (e.g. third-party iframe storage disabled).
class _LocalStorage implements HistoryStorage {
  static const _key = 'flutter_db_inspector.queryHistory.v1';
  final _fallback = MemoryHistoryStorage();

  @override
  String? read() {
    try {
      return web.window.localStorage.getItem(_key);
    } on Object {
      return _fallback.read();
    }
  }

  @override
  void write(String value) {
    try {
      web.window.localStorage.setItem(_key, value);
    } on Object {
      _fallback.write(value);
    }
  }
}

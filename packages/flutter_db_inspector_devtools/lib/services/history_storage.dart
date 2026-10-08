import 'history_storage_memory.dart'
    if (dart.library.js_interop) 'history_storage_web.dart' as impl;

/// Persists the SQL query history on the client (browser `localStorage` in
/// DevTools; memory elsewhere). Nothing is ever stored in the app.
abstract interface class HistoryStorage {
  String? read();
  void write(String value);

  /// The platform default.
  factory HistoryStorage() => impl.createHistoryStorage();
}

/// In-memory storage, used in tests and outside the browser.
class MemoryHistoryStorage implements HistoryStorage {
  MemoryHistoryStorage([this._value]);

  String? _value;

  @override
  String? read() => _value;

  @override
  void write(String value) => _value = value;
}

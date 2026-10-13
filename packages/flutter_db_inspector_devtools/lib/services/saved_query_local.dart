import 'saved_query_local_memory.dart'
    if (dart.library.js_interop) 'saved_query_local_web.dart' as impl;
import 'saved_query_store.dart';

/// The page's own storage (browser `localStorage` of DevTools, key
/// `flutter_db_inspector.savedQueries.v1`; memory outside the browser).
/// Used when the Dart Tooling Daemon cannot store saved queries.
SavedQueryBackend createLocalSavedQueryBackend() =>
    impl.createLocalSavedQueryBackend();

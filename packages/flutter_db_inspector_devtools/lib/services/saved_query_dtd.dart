import 'package:devtools_app_shared/service.dart';
import 'package:dtd/dtd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' show RpcException;

import 'saved_query_store.dart';

/// The file operations [DtdSavedQueryBackend] needs from the Dart Tooling
/// Daemon; a seam for tests.
abstract interface class DtdFiles {
  /// Identifies the current DTD connection (cached lookups are dropped when
  /// it changes); `null` while there is none.
  Object? get session;

  /// Directories with a `pubspec.yaml` inside the IDE workspace roots.
  Future<List<Uri>> projectRoots();

  /// The file's text; `null` when it does not exist.
  Future<String?> read(Uri file);

  /// Creates or replaces the file.
  Future<void> write(Uri file, String contents);
}

/// [DtdFiles] through DevTools' [DTDManager] (`dtdManager`).
class DtdManagerFiles implements DtdFiles {
  DtdManagerFiles(this.manager);

  final DTDManager manager;

  DartToolingDaemon get _dtd =>
      manager.connection.value ??
      (throw StateError('No Dart Tooling Daemon connection.'));

  @override
  Object? get session => manager.connection.value;

  @override
  Future<List<Uri>> projectRoots() async =>
      (await manager.projectRoots())?.uris ?? const [];

  @override
  Future<String?> read(Uri file) async {
    try {
      return (await _dtd.readFileAsString(file)).content;
    } on RpcException catch (e) {
      if (e.code == RpcErrorCodes.kFileDoesNotExist) return null;
      rethrow;
    }
  }

  @override
  Future<void> write(Uri file, String contents) =>
      _dtd.writeFileAsString(file, contents);
}

/// Keeps an app's saved queries in its project, next to the build output:
/// `<project>/.dart_tool/flutter_db_inspector/saved_queries.json`, where
/// `<project>` is the DTD project root whose `pubspec.yaml` is named like
/// the app. When DTD cannot create the sub-directory the file is
/// `<project>/.dart_tool/flutter_db_inspector_saved_queries.json`.
///
/// Throws (so the store falls back to the browser's storage) when there is
/// no DTD connection or no project for the app. DTD only serves files
/// inside the IDE workspace roots.
class DtdSavedQueryBackend implements SavedQueryBackend {
  DtdSavedQueryBackend(this.files);

  final DtdFiles files;

  static const directoryFile = '.dart_tool/flutter_db_inspector/'
      'saved_queries.json';
  static const flatFile = '.dart_tool/flutter_db_inspector_saved_queries.json';

  Object? _session;

  /// app → project root (`null`: none).
  final _roots = <String, Uri?>{};

  @override
  String get name => 'Dart Tooling Daemon';

  @override
  Future<String?> read(String app) async {
    final root = await _root(app);
    return await files.read(_file(root, directoryFile)) ??
        await files.read(_file(root, flatFile));
  }

  @override
  Future<void> write(String app, String contents) async {
    final root = await _root(app);
    try {
      await files.write(_file(root, directoryFile), contents);
    } on Object {
      await files.write(_file(root, flatFile), contents);
    }
  }

  Future<Uri> _root(String app) async {
    final session = files.session;
    if (session == null) {
      throw StateError('No Dart Tooling Daemon connection.');
    }
    if (!identical(session, _session)) {
      _session = session;
      _roots.clear();
    }
    final root = _roots.containsKey(app)
        ? _roots[app]
        : _roots[app] = await _findRoot(app);
    if (root == null) throw StateError('No project named "$app" in DTD.');
    return root;
  }

  Future<Uri?> _findRoot(String app) async {
    if (app == unknownApp) return null;
    for (final root in await files.projectRoots()) {
      try {
        final pubspec = await files.read(_file(root, 'pubspec.yaml'));
        if (pubspec != null && pubspecName(pubspec) == app) return root;
      } on Object {
        continue; // Unreadable: not ours.
      }
    }
    return null;
  }

  static Uri _file(Uri root, String path) =>
      (root.path.endsWith('/') ? root : root.replace(path: '${root.path}/'))
          .resolve(path);

  /// The `name:` of a pubspec.yaml.
  static String? pubspecName(String pubspec) =>
      _name.firstMatch(pubspec)?.group(1);

  static final _name = RegExp(
    r'''^name:\s*['"]?([A-Za-z_][A-Za-z0-9_]*)''',
    multiLine: true,
  );
}

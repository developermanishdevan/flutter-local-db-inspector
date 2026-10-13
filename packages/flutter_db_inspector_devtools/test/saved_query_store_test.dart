import 'dart:convert';

import 'package:flutter_db_inspector_devtools/services/saved_query_dtd.dart';
import 'package:flutter_db_inspector_devtools/services/saved_query_store.dart';
import 'package:flutter_test/flutter_test.dart';

SavedQueryStore _store(List<SavedQueryBackend> backends, {List<String>? log}) {
  var clock = 100;
  var ids = 0;
  return SavedQueryStore(
    backends,
    now: () => clock++,
    newId: () => 'q${++ids}',
    log: log?.add,
  );
}

List<String> _names(List<SavedQueryGroup> groups, String app) =>
    [for (final q in groups.firstWhere((g) => g.app == app).queries) q.name];

/// Fails every read and write, like DTD without a connection.
class _Broken implements SavedQueryBackend {
  @override
  String get name => 'broken';

  @override
  Future<String?> read(String app) async => throw StateError('offline');

  @override
  Future<void> write(String app, String contents) async =>
      throw StateError('offline');
}

/// A scripted DTD file system.
class _FakeDtd implements DtdFiles {
  _FakeDtd(this.files, {this.roots = const []});

  final Map<Uri, String> files;
  final List<Uri> roots;
  Object? connection = Object();

  /// Writes to paths containing this fail (e.g. a missing directory).
  String? failWritesUnder;
  final writes = <Uri>[];

  @override
  Object? get session => connection;

  @override
  Future<List<Uri>> projectRoots() async => roots;

  @override
  Future<String?> read(Uri file) async => files[file];

  @override
  Future<void> write(Uri file, String contents) async {
    if (failWritesUnder case final dir? when file.path.contains(dir)) {
      throw StateError('no such directory');
    }
    writes.add(file);
    files[file] = contents;
  }
}

void main() {
  group('SavedQueryStore', () {
    test('upserts by name ignoring case, keeping the id', () async {
      final backend = MemorySavedQueryBackend();
      final store = _store([backend]);

      await store.save('app', ' Users ', ' SELECT * FROM users ',
          databaseType: 'sqlite');
      await store.save('app', 'active', 'SELECT 1');
      final groups = await store.save('app', 'users', 'SELECT id FROM users');

      final queries = groups.single.queries;
      expect(queries.map((q) => q.name), ['active', 'users']);
      final users = queries.last;
      expect(users.id, 'q1');
      expect(users.sql, 'SELECT id FROM users');
      expect(users.databaseType, 'sqlite');
      expect(users.createdAt, 100);
      expect(users.updatedAt, 102);

      final stored = jsonDecode(backend.contents!) as Map;
      expect(stored['version'], 1);
      expect((stored['apps'] as Map)['app'], hasLength(2));
    });

    test('keeps apps apart; current app first, then by name', () async {
      final store = _store([MemorySavedQueryBackend()]);
      await store.save('zeta', 'z', 'SELECT 1');
      await store.save('alpha', 'a', 'SELECT 2');
      await store.save('mid', 'same', 'SELECT 3');
      await store.save('alpha', 'same', 'SELECT 4');

      final groups = await store.list('mid');
      expect(groups.map((g) => g.app), ['mid', 'alpha', 'zeta']);
      expect(_names(groups, 'alpha'), ['a', 'same']);
      expect(_names(groups, 'mid'), ['same']);
      expect(
          (await store.list(null)).map((g) => g.app), ['alpha', 'mid', 'zeta']);
    });

    test('delete drops the query, then the empty app', () async {
      final store = _store([MemorySavedQueryBackend()]);
      await store.save('a', 'one', 'SELECT 1');
      await store.save('a', 'two', 'SELECT 2');
      await store.save('b', 'three', 'SELECT 3');

      expect(_names(await store.delete('a', 'q1'), 'a'), ['two']);
      final groups = await store.delete('a', 'q2', current: 'a');
      expect(groups.map((g) => g.app), ['b']);
      expect((await store.delete('a', 'missing')).map((g) => g.app), ['b']);
    });

    test('concurrent saves are not lost', () async {
      final store = _store([MemorySavedQueryBackend()]);
      await Future.wait([
        for (var i = 0; i < 5; i++) store.save('app', 'q$i', 'SELECT $i'),
      ]);
      expect((await store.list('app')).single.queries, hasLength(5));
    });

    test('falls back to the next backend on errors', () async {
      final log = <String>[];
      final local = MemorySavedQueryBackend();
      final store = _store([_Broken(), local], log: log);

      await store.save('app', 'x', 'SELECT 1');
      expect(_names(await store.list('app'), 'app'), ['x']);
      expect(local.contents, contains('SELECT 1'));
      expect(log.first, contains('broken unavailable'));
    });

    test('ignores malformed stored data', () async {
      final store = _store([MemorySavedQueryBackend('{not json')]);
      expect(await store.list('app'), isEmpty);
      final groups = await store.save('app', 'x', 'SELECT 1');
      expect(_names(groups, 'app'), ['x']);
    });
  });

  group('DtdSavedQueryBackend', () {
    final root = Uri.parse('file:///work/sfa_app');
    final other = Uri.parse('file:///work/tools/');
    final pubspecs = {
      Uri.parse('file:///work/sfa_app/pubspec.yaml'): 'name: sfa_app\n',
      Uri.parse('file:///work/tools/pubspec.yaml'): "name: 'tools'\n",
    };
    final file = Uri.parse(
        'file:///work/sfa_app/.dart_tool/flutter_db_inspector/saved_queries.json');
    final flat = Uri.parse(
        'file:///work/sfa_app/.dart_tool/flutter_db_inspector_saved_queries.json');

    test('stores in the project named like the app', () async {
      final dtd = _FakeDtd({...pubspecs}, roots: [other, root]);
      final local = MemorySavedQueryBackend();
      final store = _store([DtdSavedQueryBackend(dtd), local]);

      await store.save('sfa_app', 'x', 'SELECT 1');
      expect(dtd.writes, [file]);
      expect(local.contents, isNull);
      expect(_names(await store.list('sfa_app'), 'sfa_app'), ['x']);
    });

    test('uses .dart_tool/ directly when the directory cannot be created',
        () async {
      final dtd = _FakeDtd({...pubspecs}, roots: [root])
        ..failWritesUnder = '/flutter_db_inspector/';
      final store =
          _store([DtdSavedQueryBackend(dtd), MemorySavedQueryBackend()]);

      await store.save('sfa_app', 'x', 'SELECT 1');
      expect(dtd.writes, [flat]);
      expect(_names(await store.list('sfa_app'), 'sfa_app'), ['x']);
    });

    test('falls back without a connection, a project or a known app', () async {
      final dtd = _FakeDtd({...pubspecs}, roots: [root, other]);
      final local = MemorySavedQueryBackend();
      final store = _store([DtdSavedQueryBackend(dtd), local]);

      await store.save('unrelated_app', 'a', 'SELECT 1');
      await store.save(unknownApp, 'b', 'SELECT 2');
      dtd.connection = null;
      await store.save('sfa_app', 'c', 'SELECT 3');
      expect(dtd.writes, isEmpty);
      expect(
        (await store.list('sfa_app')).map((g) => g.app),
        ['sfa_app', unknownApp, 'unrelated_app'],
      );

      // Back online: the project's file again (the browser's list is not
      // merged in).
      dtd.connection = Object();
      expect(await store.list('sfa_app'), isEmpty);
    });

    test('pubspecName', () {
      expect(DtdSavedQueryBackend.pubspecName('name: a_b\n'), 'a_b');
      expect(
        DtdSavedQueryBackend.pubspecName('# c\nversion: 1.0.0\nname: "x"\n'),
        'x',
      );
      expect(DtdSavedQueryBackend.pubspecName('  name: nested\n'), isNull);
    });
  });
}

import 'dart:convert';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_shared_preferences/flutter_db_inspector_shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _initial = <String, Object>{
  'theme': 'dark',
  'launches': 42,
  'ratio': 1.5,
  'onboarded': true,
  'tags': <String>['a', 'b'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InspectorRouter router;

  InspectorRouter routerFor(DbAdapter adapter) => InspectorRouter(
        registry: DbRegistry()..register('prefs', adapter),
        config: () => const InspectorConfig(mode: InspectorMode.fullAccess),
      );

  Future<Map<String, Object?>> call(String method,
      [Map<String, Object?> p = const {}]) async {
    return jsonDecode(await router.handleRaw(jsonEncode({
      'method': method,
      'params': {'databaseId': 'prefs', ...p},
    }))) as Map<String, Object?>;
  }

  Map<String, Object?> ok(Map<String, Object?> r) {
    expect(r['success'], isTrue, reason: '$r');
    return r['result']! as Map<String, Object?>;
  }

  String errorCode(Map<String, Object?> r) =>
      (r['error']! as Map<String, Object?>)['code']! as String;

  Future<Map<Object?, List<Object?>>> rows() async {
    final page = ok(await call(
        Methods.rowsQuery, {'table': SharedPreferencesStore.defaultName}));
    final values = [
      for (final r in page['rows']! as List<Object?>)
        (r! as Map<String, Object?>)['values']! as List<Object?>,
    ];
    return {for (final v in values) v[0]: v};
  }

  Future<Map<String, Object?>> update(String key, Object? value) =>
      call(Methods.rowUpdate, {
        'table': SharedPreferencesStore.defaultName,
        'key': {'key': key},
        'values': {'value': value},
      });

  Future<Map<String, Object?>> insert(String key, Object? value) =>
      call(Methods.rowInsert, {
        'table': SharedPreferencesStore.defaultName,
        'values': {'key': key, 'value': value},
      });

  group('legacy SharedPreferences', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues(_initial);
      prefs = await SharedPreferences.getInstance();
      router = routerFor(SharedPreferencesAdapter(prefs));
    });

    test('lists a single store with typed values', () async {
      final list = ok(await call(Methods.databaseList));
      final db = (list['databases']! as List<Object?>).first! as Map;
      expect(db['type'], 'shared_preferences');
      expect(db['dataModel'], 'keyValue');

      final schema = ok(await call(Methods.schemaList));
      final entities = schema['entities']! as List<Object?>;
      expect(entities, hasLength(1));
      expect((entities.single! as Map)['name'], 'shared_preferences');
      expect((entities.single! as Map)['rowCount'], 5);

      final all = await rows();
      expect(all['launches'], ['launches', 42, 'int']);
      expect(all['ratio'], ['ratio', 1.5, 'double']);
      expect(all['onboarded'], ['onboarded', true, 'bool']);
      expect(all['tags'], [
        'tags',
        {
          r'$type': 'json',
          'value': ['a', 'b'],
        },
        'List',
      ]);
    });

    test('updates keep the original type', () async {
      ok(await update('launches', 43));
      expect(prefs.get('launches'), 43);
      ok(await update('launches', '44'));
      expect(prefs.get('launches'), 44);
      ok(await update('ratio', 2));
      expect(prefs.get('ratio'), isA<double>());
      expect(prefs.getDouble('ratio'), 2.0);
      ok(await update('onboarded', 'false'));
      expect(prefs.getBool('onboarded'), isFalse);
      ok(await update('tags', {
        r'$type': 'json',
        'value': ['x'],
      }));
      expect(prefs.getStringList('tags'), ['x']);
    });

    test('rejects values that do not fit the current type', () async {
      expect(errorCode(await update('launches', 'many')), 'INVALID_REQUEST');
      expect(errorCode(await update('launches', 1.5)), 'INVALID_REQUEST');
      expect(errorCode(await update('onboarded', 1)), 'INVALID_REQUEST');
      expect(errorCode(await update('theme', 3)), 'INVALID_REQUEST');
      expect(
        errorCode(await update('tags', {
          r'$type': 'json',
          'value': [1, 2],
        })),
        'INVALID_REQUEST',
      );
      expect(prefs.getInt('launches'), 42);
      expect(prefs.getString('theme'), 'dark');
    });

    test('inserts infer the type', () async {
      ok(await insert('count', 7));
      ok(await insert('pi', 3.14));
      ok(await insert('name', 'Asha'));
      ok(await insert('flag', false));
      ok(await insert('list', {
        r'$type': 'json',
        'value': ['p', 'q'],
      }));
      expect(prefs.getInt('count'), 7);
      expect(prefs.getDouble('pi'), 3.14);
      expect(prefs.getString('name'), 'Asha');
      expect(prefs.getBool('flag'), isFalse);
      expect(prefs.getStringList('list'), ['p', 'q']);

      expect(
        errorCode(await insert('map', {
          r'$type': 'json',
          'value': {'a': 1},
        })),
        'INVALID_REQUEST',
      );
      expect(errorCode(await insert('nothing', null)), 'INVALID_REQUEST');
      expect(errorCode(await insert('theme', 'light')), 'INVALID_REQUEST');
    });

    test('delete and clear', () async {
      ok(await call(Methods.rowDelete, {
        'table': SharedPreferencesStore.defaultName,
        'key': {'key': 'theme'},
      }));
      expect(prefs.containsKey('theme'), isFalse);
      final cleared = ok(await call(
          Methods.tableClear, {'table': SharedPreferencesStore.defaultName}));
      expect(cleared['affectedRows'], 4);
      expect(prefs.getKeys(), isEmpty);
    });

    test('filters and searches', () async {
      final search = ok(await call(Methods.rowsQuery, {
        'table': SharedPreferencesStore.defaultName,
        'search': 'dark',
      }));
      expect(search['total'], 1);
      final typed = ok(await call(Methods.rowsQuery, {
        'table': SharedPreferencesStore.defaultName,
        'filters': [
          {'column': 'type', 'operator': 'equals', 'value': 'bool'},
        ],
      }));
      expect(typed['total'], 1);
    });
  });

  group('SharedPreferencesAsync', () {
    late SharedPreferencesAsync prefs;

    setUp(() async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      prefs = SharedPreferencesAsync();
      for (final e in _initial.entries) {
        switch (e.value) {
          case final String v:
            await prefs.setString(e.key, v);
          case final int v:
            await prefs.setInt(e.key, v);
          case final double v:
            await prefs.setDouble(e.key, v);
          case final bool v:
            await prefs.setBool(e.key, v);
          case final List<String> v:
            await prefs.setStringList(e.key, v);
        }
      }
      router = routerFor(SharedPreferencesAdapter.async(prefs));
    });

    test('reads current data on every request', () async {
      expect((await rows())['theme'], ['theme', 'dark', 'String']);

      // Changed outside the inspector: visible on the next request.
      await prefs.setString('theme', 'light');
      await prefs.setInt('added', 1);
      final all = await rows();
      expect(all['theme'], ['theme', 'light', 'String']);
      expect(all['added'], ['added', 1, 'int']);

      final schema = ok(await call(Methods.schemaList));
      expect(((schema['entities']! as List).single as Map)['rowCount'], 6);
    });

    test('writes keep types and are persisted', () async {
      ok(await update('launches', 50));
      expect(await prefs.getInt('launches'), 50);
      expect(errorCode(await update('launches', 'x')), 'INVALID_REQUEST');
      ok(await insert('list', {
        r'$type': 'json',
        'value': ['p'],
      }));
      expect(await prefs.getStringList('list'), ['p']);
      expect((await rows())['list']?[2], 'List');

      ok(await call(Methods.rowDelete, {
        'table': SharedPreferencesStore.defaultName,
        'key': {'key': 'theme'},
      }));
      expect(await prefs.containsKey('theme'), isFalse);

      final cleared = ok(await call(
          Methods.tableClear, {'table': SharedPreferencesStore.defaultName}));
      expect(cleared['affectedRows'], 5);
      expect(await prefs.getKeys(), isEmpty);
    });

    test('honours an allow list', () async {
      router = routerFor(
        SharedPreferencesAdapter.async(prefs, allowList: {'theme', 'new'}),
      );
      expect((await rows()).keys, ['theme']);
      ok(await insert('new', 'ok'));
      expect(errorCode(await insert('other', 'no')), 'INVALID_REQUEST');
      expect(await prefs.containsKey('other'), isFalse);

      ok(await call(
          Methods.tableClear, {'table': SharedPreferencesStore.defaultName}));
      expect(await prefs.containsKey('launches'), isTrue);
    });
  });

  group('SharedPreferencesWithCache', () {
    late SharedPreferencesWithCache prefs;

    setUp(() async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      prefs = await SharedPreferencesWithCache.create(
        cacheOptions: const SharedPreferencesWithCacheOptions(
          allowList: {'theme', 'launches', 'new'},
        ),
      );
      await prefs.setString('theme', 'dark');
      await prefs.setInt('launches', 42);
      router = routerFor(SharedPreferencesAdapter.withCache(prefs));
    });

    test('reads and writes through the cache', () async {
      final all = await rows();
      expect(all.keys, unorderedEquals(['theme', 'launches']));
      ok(await update('launches', 43));
      expect(prefs.getInt('launches'), 43);
      ok(await insert('new', true));
      expect(prefs.getBool('new'), isTrue);
      expect(errorCode(await insert('blocked', 'x')), 'INVALID_REQUEST');
    });
  });
}

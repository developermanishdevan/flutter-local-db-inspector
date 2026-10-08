import 'dart:convert';
import 'dart:io';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_get_storage/flutter_db_inspector_get_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// GetStorage always resolves the documents directory, even with a path.
final class _TempPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempPathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

final class Person {
  Person(this.name);

  final String name;

  Map<String, Object?> toJson() => {'name': name};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late GetStorage box;
  late InspectorRouter router;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('fdi_get_storage_');
    PathProviderPlatform.instance = _TempPathProvider(dir.path);
    await GetStorage.init('settings');
    box = GetStorage('settings');
  });

  tearDownAll(() async {
    // GetStorage writes its backup file without awaiting it; let it finish.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await dir.delete(recursive: true);
  });

  setUp(() async {
    await box.erase();
    await box.write('theme', 'dark');
    await box.write('launches', 42);
    await box.write('profile', {
      'name': 'Asha',
      'tags': ['a'],
    });
    await box.write('owner', Person('Ravi'));
    router = InspectorRouter(
      registry: DbRegistry()
        ..register('storage', GetStorageAdapter({'settings': box})),
      config: () => const InspectorConfig(mode: InspectorMode.fullAccess),
    );
  });

  Future<Map<String, Object?>> call(String method,
          [Map<String, Object?> p = const {}]) async =>
      jsonDecode(await router.handleRaw(jsonEncode({
        'method': method,
        'params': {'databaseId': 'storage', ...p},
      }))) as Map<String, Object?>;

  Map<String, Object?> ok(Map<String, Object?> r) {
    expect(r['success'], isTrue, reason: '$r');
    return r['result']! as Map<String, Object?>;
  }

  String errorCode(Map<String, Object?> r) =>
      (r['error']! as Map<String, Object?>)['code']! as String;

  test('lists containers and values', () async {
    final schema = ok(await call(Methods.schemaList));
    final entity = (schema['entities']! as List<Object?>).single! as Map;
    expect(entity['name'], 'settings');
    expect(entity['rowCount'], 4);

    final page = ok(await call(Methods.rowsQuery, {'table': 'settings'}));
    final values = [
      for (final r in page['rows']! as List<Object?>)
        (r! as Map<String, Object?>)['values']! as List<Object?>,
    ];
    final rows = {for (final v in values) v[0]: v};
    expect(rows['launches'], ['launches', 42, 'int']);
    expect(rows['owner'], [
      'owner',
      {
        r'$type': 'json',
        'value': {'name': 'Ravi'},
      },
      'Person',
    ]);
  });

  test('writes JSON values and refuses to replace custom objects', () async {
    ok(await call(Methods.rowInsert, {
      'table': 'settings',
      'values': {'key': 'locale', 'value': 'ta'},
    }));
    expect(box.read<String>('locale'), 'ta');

    ok(await call(Methods.rowUpdate, {
      'table': 'settings',
      'key': {'key': 'launches'},
      'values': {'value': 43},
    }));
    expect(box.read<int>('launches'), 43);

    expect(
      errorCode(await call(Methods.rowUpdate, {
        'table': 'settings',
        'key': {'key': 'owner'},
        'values': {
          'value': {
            r'$type': 'json',
            'value': {'name': 'x'},
          },
        },
      })),
      'UNSUPPORTED_OPERATION',
    );

    ok(await call(Methods.rowDelete, {
      'table': 'settings',
      'key': {'key': 'theme'},
    }));
    expect(box.hasData('theme'), isFalse);

    final cleared = ok(await call(Methods.tableClear, {'table': 'settings'}));
    expect(cleared['affectedRows'], 4);
    expect(box.getKeys<Iterable<String>>(), isEmpty);
  });
}

import 'dart:convert';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_secure_storage/flutter_db_inspector_secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _secret = 'sk_live_supersecret';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FlutterSecureStorage storage;
  late InspectorRouter router;

  void use(SecureStorageAdapter adapter) => router = InspectorRouter(
        registry: DbRegistry()..register('secrets', adapter),
        config: () => const InspectorConfig(mode: InspectorMode.fullAccess),
      );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'api_token': _secret,
      'refresh_token': 'rt_0123456789',
    });
    storage = const FlutterSecureStorage();
    use(SecureStorageAdapter(storage));
  });

  Future<String> raw(String method, [Map<String, Object?> p = const {}]) =>
      router.handleRaw(jsonEncode({
        'method': method,
        'params': {'databaseId': 'secrets', ...p},
      }));

  Future<Map<String, Object?>> call(String method,
          [Map<String, Object?> p = const {}]) async =>
      jsonDecode(await raw(method, p)) as Map<String, Object?>;

  Map<String, Object?> ok(Map<String, Object?> r) {
    expect(r['success'], isTrue, reason: '$r');
    return r['result']! as Map<String, Object?>;
  }

  String errorCode(Map<String, Object?> r) =>
      (r['error']! as Map<String, Object?>)['code']! as String;

  const table = {'table': SecureStorageStore.defaultName};

  test('lists keys with masked values', () async {
    final schema = ok(await call(Methods.schemaList));
    final entity = (schema['entities']! as List<Object?>).single! as Map;
    expect(entity['name'], 'secure_storage');
    expect(entity['rowCount'], 2);

    final response = await raw(Methods.rowsQuery, table);
    expect(response, isNot(contains('supersecret')));
    final page = jsonDecode(response) as Map<String, Object?>;
    final rows = ((page['result']! as Map)['rows']! as List<Object?>)
        .map((r) => (r! as Map)['values']! as List<Object?>)
        .toList();
    expect(rows.map((v) => v[0]), ['api_token', 'refresh_token']);
    expect(rows.first[1], {r'$type': 'masked'});
  });

  test('search, filters and value.read do not leak secrets', () async {
    final search =
        ok(await call(Methods.rowsQuery, {...table, 'search': 'supersecret'}));
    expect(search['total'], 0);
    final filtered = ok(await call(Methods.rowsQuery, {
      ...table,
      'filters': [
        {'column': 'value', 'operator': 'startsWith', 'value': 'sk_'},
      ],
    }));
    expect(filtered['total'], 0);

    final response = await raw(Methods.valueRead, {
      ...table,
      'key': {'key': 'api_token'},
      'column': 'value',
    });
    expect(response, isNot(contains('supersecret')));
    expect(errorCode(jsonDecode(response) as Map<String, Object?>),
        'PERMISSION_DENIED');
  });

  test('reveals values only when asked', () async {
    use(SecureStorageAdapter(storage, revealValues: true));
    final page = ok(await call(Methods.rowsQuery, table));
    final first = ((page['rows']! as List).first as Map)['values'] as List;
    expect(first, ['api_token', _secret, 'String']);
    final chunk = ok(await call(Methods.valueRead, {
      ...table,
      'key': {'key': 'api_token'},
      'column': 'value',
    }));
    expect(utf8.decode(base64Decode(chunk['base64']! as String)), _secret);
  });

  test('writes strings and rejects other values', () async {
    ok(await call(Methods.rowInsert, {
      ...table,
      'values': {'key': 'pin', 'value': '1234'},
    }));
    expect(await storage.read(key: 'pin'), '1234');

    ok(await call(Methods.rowUpdate, {
      ...table,
      'key': {'key': 'api_token'},
      'values': {'value': 'rotated'},
    }));
    expect(await storage.read(key: 'api_token'), 'rotated');

    expect(
      errorCode(await call(Methods.rowUpdate, {
        ...table,
        'key': {'key': 'api_token'},
        'values': {'value': 42},
      })),
      'INVALID_REQUEST',
    );
    expect(
      errorCode(await call(Methods.rowInsert, {
        ...table,
        'values': {'key': 'n', 'value': null},
      })),
      'INVALID_REQUEST',
    );

    ok(await call(Methods.rowDelete, {
      ...table,
      'key': {'key': 'refresh_token'},
    }));
    expect(await storage.containsKey(key: 'refresh_token'), isFalse);

    final cleared = ok(await call(Methods.tableClear, table));
    expect(cleared['affectedRows'], 2);
    expect(await storage.readAll(), isEmpty);
  });

  test('sees keys written outside the inspector', () async {
    await storage.write(key: 'late', value: 'x');
    final schema = ok(await call(Methods.schemaList));
    expect(((schema['entities']! as List).single as Map)['rowCount'], 3);
  });
}

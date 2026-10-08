import 'dart:convert';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  tearDown(DbInspector.registry.clear);

  Future<List<Object?>> listDatabases() async {
    final response = jsonDecode(
      await DbInspector.router
          .handleRaw(jsonEncode({'method': Methods.databaseList})),
    ) as Map<String, Object?>;
    return ((response['result'] as Map?)?['databases'] as List?) ?? const [];
  }

  test('initialize registers the databases list', () async {
    DbInspector.initialize(
      enabled: true,
      databases: [
        InspectorDatabase(
          name: 'app_database',
          adapter:
              KeyValueAdapter(type: 'hive', stores: () => [MemoryStore('a')]),
        ),
        InspectorDatabase(
          name: 'cache',
          adapter:
              KeyValueAdapter(type: 'hive', stores: () => [MemoryStore('b')]),
          readOnly: true,
        ),
      ],
    );
    final dbs = await listDatabases();
    expect([for (final d in dbs) (d! as Map)['id']], ['app_database', 'cache']);
    expect((dbs.last! as Map)['readOnly'], isTrue);

    // Databases opened later can still be added.
    DbInspector.registerDatabase(
      name: 'late',
      adapter: KeyValueAdapter(type: 'hive', stores: () => const []),
    );
    expect(await listDatabases(), hasLength(3));
  });

  test('duplicate names in the list are rejected', () {
    final adapter = KeyValueAdapter(type: 'hive', stores: () => const []);
    expect(
      () => DbInspector.initialize(
        enabled: true,
        databases: [
          InspectorDatabase(name: 'main', adapter: adapter),
          InspectorDatabase(name: 'main', adapter: adapter),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('a disabled inspector registers nothing', () {
    DbInspector.initialize(
      enabled: false,
      databases: [
        InspectorDatabase(
          name: 'secret',
          adapter: KeyValueAdapter(type: 'hive', stores: () => const []),
        ),
      ],
    );
    expect(DbInspector.registry.databases, isEmpty);
    expect(DbInspector.isEnabled, isFalse);
  });
}

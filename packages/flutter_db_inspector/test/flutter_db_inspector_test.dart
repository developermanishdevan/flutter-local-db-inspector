import 'dart:convert';

import 'package:flutter_db_inspector/flutter_db_inspector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('one import exposes the runtime and every connector', () {
    // Compile-time check that every connector is exported.
    const connectors = <Type>[
      SqliteAdapter,
      DriftAdapter,
      IsarAdapter,
      ObjectBoxAdapter,
      RealmAdapter,
      SembastAdapter,
      HiveAdapter,
      SharedPreferencesAdapter,
      SecureStorageAdapter,
      GetStorageAdapter,
    ];
    expect(connectors, hasLength(10));
  });

  test('initialize(databases: [...]) with different engines', () async {
    final db = await newDatabaseFactoryMemory().openDatabase('app.db');
    await intMapStoreFactory
        .store('notes')
        .add(db, {'title': 'Hello', 'done': false});
    SharedPreferences.setMockInitialValues({'theme': 'dark', 'launches': 3});
    final prefs = await SharedPreferences.getInstance();

    DbInspector.initialize(
      enabled: true,
      databases: [
        InspectorDatabase(name: 'notes', adapter: SembastAdapter(db)),
        InspectorDatabase(
            name: 'preferences', adapter: SharedPreferencesAdapter(prefs)),
      ],
    );

    Future<Map<String, Object?>> call(String method,
        [Map<String, Object?> params = const {}]) async {
      final raw = await DbInspector.router
          .handleRaw(jsonEncode({'method': method, 'params': params}));
      final response = jsonDecode(raw) as Map<String, Object?>;
      expect(response['success'], isTrue, reason: raw);
      return response['result']! as Map<String, Object?>;
    }

    final list = await call(Methods.databaseList);
    final dbs = {
      for (final d in list['databases']! as List)
        (d as Map)['id']: d['dataModel'],
    };
    expect(dbs, {'notes': 'document', 'preferences': 'keyValue'});

    final notes = await call(
        Methods.rowsQuery, {'databaseId': 'notes', 'table': 'notes'});
    expect(notes['total'], 1);
    final prefsRows = await call(Methods.rowsQuery, {
      'databaseId': 'preferences',
      'table': 'shared_preferences',
      'search': 'dark',
    });
    expect(prefsRows['total'], 1);
    await db.close();
  });
}

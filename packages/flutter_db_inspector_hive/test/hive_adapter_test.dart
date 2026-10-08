import 'dart:convert';
import 'dart:io';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_hive/flutter_db_inspector_hive.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:test/test.dart';

final class Person {
  Person(this.name, this.age);

  factory Person.fromJson(Map<Object?, Object?> json) =>
      Person(json['name']! as String, json['age']! as int);

  final String name;
  final int age;

  Map<String, Object?> toJson() => {'name': name, 'age': age};
}

/// Hand-written adapter (no code generation).
final class PersonAdapter extends TypeAdapter<Person> {
  @override
  int get typeId => 1;

  @override
  Person read(BinaryReader reader) =>
      Person(reader.readString(), reader.readInt());

  @override
  void write(BinaryWriter writer, Person obj) {
    writer
      ..writeString(obj.name)
      ..writeInt(obj.age);
  }
}

void main() {
  late Directory dir;
  late Box<Object?> settings;
  late LazyBox<Object?> cache;
  late Box<Person> people;
  late InspectorRouter router;
  late List<BoxBase<Object?>> opened;

  setUpAll(() => Hive.registerAdapter(PersonAdapter()));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fdi_hive_');
    Hive.init(dir.path);
    settings = await Hive.openBox<Object?>('settings');
    await settings.putAll({
      'theme': 'dark',
      'launches': 42,
      'profile': {
        'name': 'Asha',
        'tags': ['a', 'b'],
      },
      'owner': Person('Ravi', 31),
      7: 'seven',
    });
    cache = await Hive.openLazyBox<Object?>('cache');
    await cache.putAll({for (var i = 0; i < 25; i++) i: 'entry $i'});
    people = await Hive.openBox<Person>('people');
    await people.put('ravi', Person('Ravi', 31));
    opened = [settings, cache, people];

    router = InspectorRouter(
      registry: DbRegistry()
        ..register('hive', HiveAdapter.dynamic(() => opened))
        ..register(
          'decoding',
          HiveAdapter(
            [people],
            decode: (json, previous) => previous is Person || previous == null
                ? Person.fromJson(json! as Map<Object?, Object?>)
                : json,
          ),
        ),
      config: () => const InspectorConfig(mode: InspectorMode.fullAccess),
    );
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  Future<Map<String, Object?>> call(String method,
      [Map<String, Object?> p = const {}, String db = 'hive']) async {
    final r = jsonDecode(await router.handleRaw(jsonEncode({
      'method': method,
      'params': {'databaseId': db, ...p},
    }))) as Map<String, Object?>;
    return r;
  }

  Map<String, Object?> ok(Map<String, Object?> r) {
    expect(r['success'], isTrue, reason: '$r');
    return r['result']! as Map<String, Object?>;
  }

  String errorCode(Map<String, Object?> r) =>
      (r['error']! as Map<String, Object?>)['code']! as String;

  Map<Object?, Map<String, Object?>> rowsByKey(Map<String, Object?> page) => {
        for (final r in page['rows']! as List<Object?>)
          ((r! as Map<String, Object?>)['values']! as List<Object?>)[0]:
              r as Map<String, Object?>,
      };

  test('lists open boxes as key/value entities', () async {
    final list = ok(await call(Methods.databaseList));
    final db = (list['databases']! as List<Object?>).first! as Map;
    expect(db['dataModel'], 'keyValue');
    expect(db['type'], 'hive');

    final schema = ok(await call(Methods.schemaList));
    final entities =
        (schema['entities']! as List<Object?>).cast<Map<String, Object?>>();
    expect(entities.map((e) => e['name']), ['cache', 'people', 'settings']);
    expect(entities.every((e) => e['kind'] == 'box'), isTrue);
    expect(entities.first['rowCount'], 25);
  });

  test('boxes opened later appear and closed boxes disappear', () async {
    final late = await Hive.openBox<Object?>('late');
    opened = [...opened, late];
    var entities = ok(await call(Methods.schemaList))['entities']! as List;
    expect(entities.map((e) => (e as Map)['name']), contains('late'));

    await late.close();
    entities = ok(await call(Methods.schemaList))['entities']! as List;
    expect(entities.map((e) => (e as Map)['name']), isNot(contains('late')));
  });

  test('reads int and String keys and custom objects via toJson', () async {
    final page = ok(await call(Methods.rowsQuery, {'table': 'settings'}));
    final rows = rowsByKey(page);
    expect(rows['theme']!['values'], ['theme', 'dark', 'String']);
    expect(rows['launches']!['values'], ['launches', 42, 'int']);
    expect(rows[7]!['key'], {'key': 7});
    expect(rows['owner']!['values'], [
      'owner',
      {
        r'$type': 'json',
        'value': {'name': 'Ravi', 'age': 31},
      },
      'Person',
    ]);

    final search = ok(
        await call(Methods.rowsQuery, {'table': 'settings', 'search': 'ravi'}));
    expect(search['total'], 1);
  });

  test('pages through a lazy box', () async {
    final page = ok(await call(
        Methods.rowsQuery, {'table': 'cache', 'pageSize': 10, 'page': 1}));
    expect(page['total'], 25);
    final rows = (page['rows']! as List).cast<Map<String, Object?>>();
    expect(rows, hasLength(10));
    expect(rows.first['values'], [10, 'entry 10', 'String']);

    final filtered = ok(await call(Methods.rowsQuery, {
      'table': 'cache',
      'filters': [
        {'column': 'key', 'operator': 'greaterOrEqual', 'value': 20},
      ],
      'sort': [
        {'column': 'key', 'direction': 'desc'},
      ],
    }));
    expect(filtered['total'], 5);
    expect(((filtered['rows']! as List).first as Map)['key'], {'key': 24});

    final chunk = ok(await call(Methods.valueRead, {
      'table': 'cache',
      'key': {'key': 3},
      'column': 'value'
    }));
    expect(chunk['totalBytes'], 'entry 3'.length);
  });

  test('writes JSON-native values to boxes and lazy boxes', () async {
    ok(await call(Methods.rowInsert, {
      'table': 'settings',
      'values': {'key': 'locale', 'value': 'ta'},
    }));
    expect(settings.get('locale'), 'ta');

    ok(await call(Methods.rowUpdate, {
      'table': 'settings',
      'key': {'key': 'profile'},
      'values': {
        'value': {
          r'$type': 'json',
          'value': {'name': 'Asha', 'tags': <String>[]},
        },
      },
    }));
    expect(settings.get('profile'), {'name': 'Asha', 'tags': <Object?>[]});

    ok(await call(Methods.rowUpdate, {
      'table': 'cache',
      'key': {'key': 0},
      'values': {'value': 'fresh'},
    }));
    expect(await cache.get(0), 'fresh');

    ok(await call(Methods.rowDelete, {
      'table': 'settings',
      'key': {'key': 7},
    }));
    expect(settings.containsKey(7), isFalse);

    final cleared = ok(await call(Methods.tableClear, {'table': 'cache'}));
    expect(cleared['affectedRows'], 25);
    expect(cache.isEmpty, isTrue);
  });

  test('refuses to overwrite a custom object with plain JSON', () async {
    final r = await call(Methods.rowUpdate, {
      'table': 'settings',
      'key': {'key': 'owner'},
      'values': {
        'value': {
          r'$type': 'json',
          'value': {'name': 'Mallory', 'age': 1},
        },
      },
    });
    expect(errorCode(r), 'UNSUPPORTED_OPERATION');
    expect((r['error']! as Map)['message'], contains('decode'));
    expect(settings.get('owner'), isA<Person>());
  });

  test('typed boxes reject values of another type', () async {
    final r = await call(Methods.rowInsert, {
      'table': 'people',
      'values': {'key': 'x', 'value': 'not a person'},
    });
    expect(errorCode(r), 'INVALID_REQUEST');
    expect(people.containsKey('x'), isFalse);
  });

  test('a decode callback rebuilds custom objects', () async {
    ok(await call(
      Methods.rowUpdate,
      {
        'table': 'people',
        'key': {'key': 'ravi'},
        'values': {
          'value': {
            r'$type': 'json',
            'value': {'name': 'Ravi', 'age': 32},
          },
        },
      },
      'decoding',
    ));
    final ravi = people.get('ravi')!;
    expect(ravi.age, 32);

    ok(await call(
      Methods.rowInsert,
      {
        'table': 'people',
        'values': {
          'key': 'asha',
          'value': {
            r'$type': 'json',
            'value': {'name': 'Asha', 'age': 28},
          },
        },
      },
      'decoding',
    ));
    expect(people.get('asha')?.name, 'Asha');
  });
}

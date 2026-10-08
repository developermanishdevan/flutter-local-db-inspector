// A device-free demo: a plain Dart process exposing a seeded SQLite database
// through Flutter DB Inspector, so clients can be developed and tested
// without running a Flutter app.
//
//   dart run --enable-vm-service example/inspector_server.dart [path.db]
//   dart run --enable-vm-service example/inspector_server.dart --restartable
//     (type `restart` + Enter to simulate a hot restart)
//
// Then connect from VS Code with "Flutter DB: Connect to VM Service URI…"
// using the URI printed on start-up.
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_sqlite/flutter_db_inspector_sqlite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main(List<String> args) async {
  final restartable = args.contains('--restartable');
  final dbArgs = args.where((a) => !a.startsWith('--')).toList();
  final path = dbArgs.isEmpty ? null : dbArgs.first;

  final info = await Service.getInfo();
  stdout.writeln('FDI_VM_SERVICE_URI=${info.serverUri}');

  if (!restartable) {
    await runApp(path);
  } else {
    // Simulates Flutter's hot restart at the VM level: the "app" runs in its
    // own isolate; typing `restart` kills it and starts a fresh one, which
    // re-registers the service extension under a new isolate id.
    var isolate = await Isolate.spawn(_appIsolate, path, debugName: 'app');
    stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) async {
      if (line.trim() != 'restart') return;
      isolate.kill(priority: Isolate.immediate);
      isolate = await Isolate.spawn(_appIsolate, path, debugName: 'app');
      stdout.writeln('FDI_RESTARTED');
    });
  }
  stdout
      .writeln('Flutter DB Inspector demo server is running. Ctrl+C to stop.');
  // A pending signal subscription keeps the process alive until Ctrl+C.
  await ProcessSignal.sigint.watch().first;
  exit(0);
}

Future<void> _appIsolate(String? path) async {
  await runApp(path);
  // Like Flutter's event loop, an open port keeps the app isolate alive.
  RawReceivePort();
}

/// What a Flutter app's `main` would do.
Future<void> runApp(String? path) async {
  DbInspector.initialize(
    enabled: true,
    sensitiveColumns: {'users.password'},
  );

  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    path ?? inMemoryDatabasePath,
    options: OpenDatabaseOptions(version: 1, onCreate: (db, _) => seed(db)),
  );
  DbInspector.registerDatabase(
      name: 'app_database', adapter: SqliteAdapter(db));
}

Future<void> seed(Database db) async {
  await db.execute('''
    CREATE TABLE users (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      email TEXT,
      phone TEXT,
      password TEXT,
      is_active INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )''');
  await db.execute('''
    CREATE TABLE products (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      price REAL NOT NULL,
      stock INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )''');
  await db.execute('''
    CREATE TABLE orders (
      id INTEGER PRIMARY KEY,
      user_id INTEGER REFERENCES users(id),
      total REAL,
      status TEXT,
      created_at INTEGER
    )''');
  await db.execute('CREATE INDEX idx_orders_user ON orders(user_id)');
  await db.execute('''
    CREATE TABLE edge_cases (
      id INTEGER PRIMARY KEY,
      label TEXT,
      json_value JSON,
      big_int INTEGER,
      decimal REAL,
      flag BOOLEAN,
      created DATETIME,
      data BLOB,
      long_text TEXT
    )''');
  await db.execute(
    'CREATE VIEW active_users AS SELECT id, name, email FROM users WHERE is_active = 1',
  );

  final batch = db.batch();
  const statuses = ['pending', 'paid', 'shipped', 'delivered', 'cancelled'];
  for (var i = 1; i <= 1000; i++) {
    batch.insert('users', {
      'name': 'User $i',
      'email': i % 17 == 0 ? null : 'user$i@example.com',
      'phone': '+91 98${(10000000 + i * 7919) % 100000000}',
      'password': 'pw-$i',
      'is_active': i % 4 == 0 ? 0 : 1,
      'created_at': 1700000000000 + i * 60000,
    });
  }
  for (var i = 1; i <= 5000; i++) {
    batch.insert('products', {
      'name': 'Product $i',
      'price': (i % 500) * 1.25 + 0.99,
      'stock': i % 120,
      'created_at': 1700000000000 + i * 1000,
    });
  }
  for (var i = 1; i <= 10000; i++) {
    batch.insert('orders', {
      'user_id': i % 1000 + 1,
      'total': (i % 977) * 3.5,
      'status': statuses[i % statuses.length],
      'created_at': 1700000000000 + i * 30000,
    });
  }
  batch
    ..insert('edge_cases', {
      'label': '',
      'json_value': '{"name":"John","active":true,"tags":["a","b"]}',
      'big_int': 9007199254740993,
      'decimal': 12345.6789,
      'flag': 1,
      'created': '2024-05-01T10:30:00Z',
      'data':
          Uint8List.fromList(List.generate(2 * 1024 * 1024, (i) => i % 251)),
      'long_text': 'Lorem ipsum dolor sit amet. ' * 2000,
    })
    ..insert('edge_cases', {'label': 'Unicode: தமிழ் 中文 العربية 🚀🎉'})
    ..insert('edge_cases', {'label': null, 'flag': 0, 'big_int': -42});
  await batch.commit(noResult: true);
}

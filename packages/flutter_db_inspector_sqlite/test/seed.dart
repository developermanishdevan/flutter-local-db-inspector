import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens an in-memory database containing every awkward value type the
/// inspector must survive.
Future<Database> openSeededDatabase() async {
  sqfliteFfiInit();
  final db =
      await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
  await db.execute('PRAGMA foreign_keys = ON');
  await db.execute('''
    CREATE TABLE users (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      email TEXT,
      password TEXT,
      is_active BOOLEAN NOT NULL DEFAULT 1,
      created_at INTEGER NOT NULL
    )''');
  await db.execute('CREATE UNIQUE INDEX idx_users_email ON users(email)');
  await db.execute('''
    CREATE TABLE orders (
      id INTEGER PRIMARY KEY,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      total REAL,
      status TEXT
    )''');
  await db.execute('''
    CREATE TABLE settings (
      scope TEXT NOT NULL,
      key TEXT NOT NULL,
      value TEXT,
      PRIMARY KEY (scope, key)
    ) WITHOUT ROWID''');
  await db.execute('''
    CREATE TABLE samples (
      id INTEGER PRIMARY KEY,
      label TEXT,
      payload JSON,
      big INTEGER,
      ratio REAL,
      data BLOB,
      notes TEXT
    )''');
  await db.execute(
    'CREATE VIEW active_users AS SELECT id, name FROM users WHERE is_active = 1',
  );
  await db.execute('''
    CREATE TRIGGER orders_status AFTER INSERT ON orders
    BEGIN SELECT 1; END''');

  final batch = db.batch();
  for (var i = 1; i <= 250; i++) {
    batch.insert('users', {
      'id': i,
      'name': i == 7 ? 'Zoë 🚀 Emoji' : 'User $i',
      'email': i % 10 == 0 ? null : 'user$i@example.com',
      'password': 'secret-$i',
      'is_active': i.isEven ? 1 : 0,
      'created_at': 1700000000 + i,
    });
    batch.insert('orders', {
      'user_id': i,
      'total': i * 1.5,
      'status': i % 3 == 0 ? 'shipped' : 'pending',
    });
  }
  batch.insert('settings', {'scope': 'app', 'key': 'theme', 'value': 'dark'});
  batch.insert('settings', {'scope': 'app', 'key': 'locale', 'value': 'en'});
  batch.insert('samples', {
    'label': '',
    'payload': '{"name":"John","active":true}',
    'big': 9007199254740993,
    'ratio': 3.14159,
    'data': Uint8List.fromList(List.generate(64 * 1024, (i) => i % 256)),
    'notes': 'x' * 50000,
  });
  batch.insert('samples', {'label': null});
  await batch.commit(noResult: true);
  return db;
}

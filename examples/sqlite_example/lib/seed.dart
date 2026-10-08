import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

/// Creates the demo schema and fills it with enough data to exercise
/// pagination and performance (1,000 users, 5,000 products, 10,000 orders).
Future<void> createAndSeed(Database db, int version) async {
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
      image BLOB,
      created_at INTEGER NOT NULL
    )''');
  await db.execute('''
    CREATE TABLE orders (
      id INTEGER PRIMARY KEY,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      total REAL,
      status TEXT,
      created_at INTEGER
    )''');
  await db.execute('''
    CREATE TABLE order_items (
      order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
      product_id INTEGER NOT NULL REFERENCES products(id),
      quantity INTEGER NOT NULL,
      unit_price REAL NOT NULL,
      PRIMARY KEY (order_id, product_id)
    ) WITHOUT ROWID''');
  await db.execute('''
    CREATE TABLE settings (
      key TEXT PRIMARY KEY,
      value TEXT
    )''');
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
  await db.execute('CREATE INDEX idx_orders_user ON orders(user_id)');
  await db.execute(
    'CREATE INDEX idx_orders_status ON orders(status, created_at)',
  );
  await db.execute('CREATE UNIQUE INDEX idx_users_email ON users(email)');
  await db.execute(
    'CREATE VIEW active_users AS SELECT id, name, email FROM users WHERE is_active = 1',
  );
  await db.execute('''
    CREATE TRIGGER orders_touch_stock AFTER INSERT ON order_items
    BEGIN
      UPDATE products SET stock = stock - NEW.quantity WHERE id = NEW.product_id;
    END''');

  final random = Random(42);
  const statuses = ['pending', 'paid', 'shipped', 'delivered', 'cancelled'];
  const firstNames = [
    'Asha',
    'Ravi',
    'John',
    'Meera',
    'Arun',
    'Priya',
    'Karthik',
    'Divya',
    'Sam',
    'Zoë',
  ];
  const now = 1735689600000; // 2025-01-01

  final batch = db.batch();
  for (var i = 1; i <= 1000; i++) {
    final first = firstNames[i % firstNames.length];
    batch.insert('users', {
      'id': i,
      'name': '$first ${String.fromCharCode(65 + i % 26)}. #$i',
      'email': i % 17 == 0 ? null : '${first.toLowerCase()}.$i@example.com',
      'phone': '+91 98${(10000000 + i * 7919) % 100000000}'.padRight(14, '0'),
      'password': 'pw-${random.nextInt(1 << 30)}',
      'is_active': i % 4 == 0 ? 0 : 1,
      'created_at': now - i * 3600000,
    });
  }
  for (var i = 1; i <= 5000; i++) {
    batch.insert('products', {
      'id': i,
      'name': 'Product $i',
      'price': ((i % 500) * 1.25 + 0.99),
      'stock': 1000 + i % 120,
      'image': i % 50 == 0
          ? Uint8List.fromList(List.generate(4096, (j) => (i + j) % 256))
          : null,
      'created_at': now - i * 60000,
    });
  }
  for (var i = 1; i <= 10000; i++) {
    batch.insert('orders', {
      'id': i,
      'user_id': i % 1000 + 1,
      'total': ((i % 977) * 3.5),
      'status': statuses[i % statuses.length],
      'created_at': now - i * 30000,
    });
    batch.rawInsert(
      'INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (?, ?, ?, ?)',
      [i, i % 5000 + 1, 1 + i % 3, 9.99],
    );
  }
  batch
    ..insert('settings', {'key': 'theme', 'value': 'dark'})
    ..insert('settings', {'key': 'locale', 'value': 'en_IN'})
    ..insert('settings', {
      'key': 'onboarding',
      'value': '{"done":true,"step":4}',
    })
    ..insert('edge_cases', {
      'label': '',
      'json_value':
          '{"name":"John","active":true,"tags":["a","b"],"nested":{"x":1}}',
      'big_int': 9007199254740993,
      'decimal': 12345.6789,
      'flag': 1,
      'created': '2024-05-01T10:30:00Z',
      'data': Uint8List.fromList(
        List.generate(2 * 1024 * 1024, (i) => i % 251),
      ),
      'long_text': 'Lorem ipsum dolor sit amet. ' * 2000,
    })
    ..insert('edge_cases', {'label': 'Unicode: தமிழ் 中文 العربية Ελληνικά 🚀🎉'})
    ..insert('edge_cases', {
      'label': null,
      'flag': 0,
      'big_int': -42,
      'decimal': -0.001,
    });
  await batch.commit(noResult: true);
}

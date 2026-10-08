import 'package:flutter_db_inspector_sqlite/flutter_db_inspector_sqlite.dart';
import 'package:test/test.dart';

void main() {
  bool isRead(String sql) => SqlClassifier.classify(sql).isRead;

  test('read statements', () {
    expect(isRead('SELECT * FROM users'), isTrue);
    expect(isRead('  select 1;'), isTrue);
    expect(isRead('WITH x AS (SELECT 1) SELECT * FROM x'), isTrue);
    expect(isRead('VALUES (1), (2)'), isTrue);
    expect(isRead('EXPLAIN QUERY PLAN DELETE FROM users'), isTrue);
    expect(isRead('PRAGMA table_info(users)'), isTrue);
    expect(isRead('PRAGMA main.index_list(users)'), isTrue);
    expect(isRead('PRAGMA user_version'), isTrue);
  });

  test('write statements', () {
    for (final sql in [
      'DELETE FROM users',
      'update users set name = 1',
      'INSERT INTO t VALUES (1)',
      'REPLACE INTO t VALUES (1)',
      'DROP TABLE users',
      'ALTER TABLE users ADD COLUMN x',
      'CREATE TABLE x (a)',
      'WITH x AS (SELECT 1) DELETE FROM users',
      'PRAGMA user_version = 3',
      'PRAGMA wal_checkpoint(TRUNCATE)',
      'VACUUM',
      'ATTACH DATABASE "x" AS y',
    ]) {
      expect(isRead(sql), isFalse, reason: sql);
    }
  });

  test('comments and string literals do not confuse the classifier', () {
    final c = SqlClassifier.classify(
      "-- DELETE FROM users\nSELECT 'a;DROP TABLE x' /* ; UPDATE */ FROM t;",
    );
    expect(c.statements, hasLength(1));
    expect(c.isRead, isTrue);
    expect(c.isWrappable, isTrue);
  });

  test('multiple statements are detected', () {
    final c = SqlClassifier.classify('SELECT 1; DELETE FROM users');
    expect(c.statements, hasLength(2));
    expect(c.isRead, isFalse);
  });
}

/// Lightweight SQL statement classification used to protect application
/// data: anything that is not provably read-only requires confirmation.
final class SqlClassification {
  const SqlClassification({
    required this.statements,
    required this.keyword,
    required this.isRead,
    required this.isWrappable,
  });

  /// Non-empty statements, split at top-level semicolons.
  final List<String> statements;

  /// Leading keyword of the first statement, upper-cased (e.g. `SELECT`).
  final String keyword;

  /// Statement cannot modify data.
  final bool isRead;

  /// Statement can be wrapped as `SELECT * FROM (<sql>) LIMIT n`.
  final bool isWrappable;
}

abstract final class SqlClassifier {
  static const _writeWords = {'INSERT', 'UPDATE', 'DELETE', 'REPLACE'};

  static const _readPragmas = {
    'TABLE_INFO',
    'TABLE_XINFO',
    'TABLE_LIST',
    'INDEX_LIST',
    'INDEX_INFO',
    'INDEX_XINFO',
    'FOREIGN_KEY_LIST',
    'FOREIGN_KEY_CHECK',
    'INTEGRITY_CHECK',
    'QUICK_CHECK',
    'COLLATION_LIST',
    'FUNCTION_LIST',
    'DATABASE_LIST',
  };

  static SqlClassification classify(String sql) {
    final statements = <_Statement>[];
    var current = _Statement();
    final length = sql.length;
    var i = 0;
    while (i < length) {
      final ch = sql[i];
      final next = i + 1 < length ? sql[i + 1] : '';
      if (ch == '-' && next == '-') {
        final end = sql.indexOf('\n', i);
        current.text.write(' ');
        i = end < 0 ? length : end + 1;
        continue;
      }
      if (ch == '/' && next == '*') {
        final end = sql.indexOf('*/', i + 2);
        current.text.write(' ');
        i = end < 0 ? length : end + 2;
        continue;
      }
      if (ch == "'" || ch == '"' || ch == '`' || ch == '[') {
        final close = ch == '[' ? ']' : ch;
        var j = i + 1;
        while (j < length) {
          if (sql[j] == close) {
            // Doubled quote is an escape.
            if (close != ']' && j + 1 < length && sql[j + 1] == close) {
              j += 2;
              continue;
            }
            break;
          }
          j++;
        }
        current.text.write(sql.substring(i, j < length ? j + 1 : length));
        current.hasContent = true;
        i = j + 1;
        continue;
      }
      if (ch == ';') {
        if (current.hasContent) statements.add(current);
        current = _Statement();
        i++;
        continue;
      }
      if (_isWordChar(ch)) {
        var j = i;
        while (j < length && _isWordChar(sql[j])) {
          j++;
        }
        final word = sql.substring(i, j);
        current.words.add(word.toUpperCase());
        current.text.write(word);
        current.hasContent = true;
        i = j;
        continue;
      }
      if (ch == '=') current.hasAssignment = true;
      if (ch == '(') current.hasParen = true;
      if (ch.trim().isNotEmpty) current.hasContent = true;
      current.text.write(ch);
      i++;
    }
    if (current.hasContent) statements.add(current);

    if (statements.isEmpty) {
      return const SqlClassification(
        statements: [],
        keyword: '',
        isRead: true,
        isWrappable: false,
      );
    }
    final first = statements.first;
    final keyword = first.words.isEmpty ? '' : first.words.first;
    final isRead = statements.every(_isRead);
    return SqlClassification(
      statements: [for (final s in statements) s.text.toString().trim()],
      keyword: keyword,
      isRead: isRead,
      isWrappable:
          isRead && const {'SELECT', 'WITH', 'VALUES'}.contains(keyword),
    );
  }

  static bool _isRead(_Statement s) {
    if (s.words.isEmpty) return true;
    switch (s.words.first) {
      case 'SELECT' || 'VALUES':
        return true;
      case 'EXPLAIN':
        return true;
      case 'WITH':
        return !s.words.any(_writeWords.contains);
      case 'PRAGMA':
        if (s.hasAssignment) return false;
        if (!s.hasParen) return true;
        final name = s.words.length > 1 ? s.words[1] : '';
        // `PRAGMA schema.name(...)`
        final pragma = s.words.length > 2 && !_readPragmas.contains(name)
            ? s.words[2]
            : name;
        return _readPragmas.contains(pragma);
      default:
        return false;
    }
  }

  static bool _isWordChar(String ch) {
    final c = ch.codeUnitAt(0);
    return (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x5F ||
        c == 0x24 ||
        c > 0x7F;
  }
}

final class _Statement {
  final StringBuffer text = StringBuffer();
  final List<String> words = [];
  bool hasAssignment = false;
  bool hasParen = false;
  bool hasContent = false;
}

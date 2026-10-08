import 'package:flutter/foundation.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import 'query_history.dart';
import 'table_controller.dart';
import 'wording.dart';

/// Asks the user whether a statement that may modify data should run.
typedef ConfirmWrite = Future<bool> Function(String sql);

/// State of the SQL console of one database: text, run/cancel, results,
/// errors, the write-confirmation round trip and the client-side history.
class SqlController extends ChangeNotifier {
  SqlController({
    required this.client,
    required this.database,
    required this.history,
    this.maxRows,
  });

  final InspectorClient client;

  /// Replaced with fresh descriptors when the database list reloads.
  DatabaseDescriptor database;
  final QueryHistory history;

  /// Overrides the app's `maxSqlRows` when set.
  final int? maxRows;

  /// Column widths of the result grid.
  final columnWidths = <String, double>{};

  String sql = '';
  bool _running = false;
  SqlQueryResult? _result;
  String? _error;
  String? _notice;
  int _seq = 0;
  bool _disposed = false;

  bool get running => _running;
  SqlQueryResult? get result => _result;

  /// Error of the last run, formatted for display.
  String? get error => _error;

  /// Informational outcome ("Cancelled", "Not executed").
  String? get notice => _notice;

  List<QueryHistoryEntry> get entries => history.forDatabase(database.id);

  List<GridColumn> get gridColumns => [
        for (final c in _result?.columns ?? const <ResultColumn>[])
          GridColumn(
            name: c.name,
            valueType: c.valueType,
            declaredType: c.declaredType,
          ),
      ];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Runs [text] (or [sql]). Statements the app classifies as writes are
  /// confirmed through [confirmWrite] and resent with `allowWrite: true`.
  Future<void> run({String? text, required ConfirmWrite confirmWrite}) async {
    final statement = (text ?? sql).trim();
    if (statement.isEmpty || _running) return;
    final seq = ++_seq;
    _running = true;
    _error = null;
    _notice = null;
    _notify();
    var succeeded = false;
    try {
      SqlQueryResult result;
      try {
        result = await client.executeSql(
          database.id,
          statement,
          maxRows: maxRows,
        );
      } on InspectorClientException catch (e) {
        if (!e.requiresConfirmation || seq != _seq) rethrow;
        _running = false;
        _notify();
        final confirmed = await confirmWrite(statement);
        if (seq != _seq) return;
        if (!confirmed) {
          _notice = 'Not executed.';
          return;
        }
        _running = true;
        _notify();
        result = await client.executeSql(
          database.id,
          statement,
          allowWrite: true,
          maxRows: maxRows,
        );
      }
      if (seq != _seq) return;
      _result = result;
      succeeded = true;
    } on InspectorClientException catch (e) {
      if (seq != _seq) return;
      _error = Wording.error(e);
    } finally {
      if (seq == _seq) {
        _running = false;
        if (_notice == null) {
          history.add(
            QueryHistoryEntry(
              sql: statement,
              databaseId: database.id,
              at: DateTime.now(),
              succeeded: succeeded,
            ),
          );
        }
        _notify();
      }
    }
  }

  /// The app cannot abort a running statement; this stops waiting for it.
  void cancel() {
    if (!_running) return;
    _seq++;
    _running = false;
    _notice = 'Cancelled (the statement may still finish in the app).';
    _notify();
  }

  /// "3 rows · 1.2 ms" / "1 row affected · last insert id 7 · 0.4 ms".
  String get statusText {
    final result = _result;
    if (result == null) return '';
    final time = '${result.elapsedMs.toStringAsFixed(1)} ms';
    if (result.kind == SqlStatementKind.write) {
      final affected = result.affectedRows;
      final lastId = result.lastInsertId;
      return [
        if (affected == null)
          'Statement executed'
        else
          '${WireValues.formatCount(affected)} '
              '${affected == 1 ? 'row' : 'rows'} affected',
        if (lastId != null) 'last insert id $lastId',
        time,
      ].join(' · ');
    }
    final n = result.rowCount;
    return '${WireValues.formatCount(n)} ${n == 1 ? 'row' : 'rows'} · $time';
  }

  String copyCellText(int row, int col) {
    final rows = _result?.rows;
    if (rows == null || row >= rows.length) return '';
    return WireValues.copyText(rows[row][col]);
  }

  String rowJson(int row) {
    final result = _result;
    if (result == null || row >= result.rows.length) return '';
    return WireValues.encodeJson(
      WireValues.rowToObject(
        [for (final c in result.columns) c.name],
        result.rows[row],
      ),
      indent: '  ',
    );
  }

  /// All results as a JSON array (exact 64-bit integers).
  String resultsJson() {
    final result = _result;
    if (result == null) return '[]';
    final names = [for (final c in result.columns) c.name];
    return WireValues.encodeJson(
      [for (final r in result.rows) WireValues.rowToObject(names, r)],
      indent: '  ',
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _seq++;
    super.dispose();
  }
}

import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import '../services/host.dart';
import '../services/query_history.dart';
import '../services/sql_controller.dart';
import '../widgets/common.dart';
import '../widgets/data_grid.dart';
import '../widgets/sql_editor.dart';
import '../widgets/toolbar.dart';
import '../widgets/value_inspector.dart';

/// Asks before running a statement that may modify the app's data.
Future<bool> confirmSqlWrite(BuildContext context, String sql) =>
    showConfirmDialog(
      context,
      title: 'Run a write statement?',
      message: 'This query may modify application data.\n\n'
          '${sql.length > 400 ? '${sql.substring(0, 400)}…' : sql}',
      confirmLabel: 'Execute',
    );

/// The SQL tab: editor, Run (Ctrl/Cmd+Enter) / Cancel, results grid, timing,
/// truncation warning, errors and the client-side query history.
class QueryPage extends StatefulWidget {
  const QueryPage({
    super.key,
    required this.controller,
    required this.host,
    this.maxSqlRows = 100,
    this.connected = true,
  });

  final SqlController controller;
  final InspectorHost host;
  final int maxSqlRows;
  final bool connected;

  @override
  State<QueryPage> createState() => _QueryPageState();
}

class _QueryPageState extends State<QueryPage> {
  late final _editor = TextEditingController(text: widget.controller.sql);
  final _editorFocus = FocusNode(debugLabel: 'sql editor');
  final _gridKey = GlobalKey<DataGridState>();
  bool _historyOpen = false;
  (int, int)? _inspected;

  SqlController get _c => widget.controller;

  @override
  void didUpdateWidget(QueryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _editor.text = widget.controller.sql;
      _inspected = null;
    }
  }

  @override
  void dispose() {
    _editor.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  void _run([String? sql]) {
    if (!widget.connected) return;
    setState(() => _inspected = null);
    unawaited(
      _c.run(
        text: sql ?? selectedSql(_editor),
        confirmWrite: (statement) => confirmSqlWrite(context, statement),
      ),
    );
  }

  void _useHistory(QueryHistoryEntry entry, {required bool run}) {
    _editor.text = entry.sql;
    _c.sql = entry.sql;
    if (run) {
      _run(entry.sql);
    } else {
      _editorFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_c, _c.history]),
      builder: (context, _) {
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InspectorToolbar(
              label: 'SQL actions',
              children: [
                DevToolsButton(
                  icon: Icons.play_arrow,
                  label: 'Run',
                  tooltip: 'Run (Ctrl/Cmd+Enter)',
                  elevated: true,
                  onPressed: _c.running || !widget.connected ? null : _run,
                ),
                DevToolsButton(
                  icon: Icons.stop,
                  label: 'Cancel',
                  tooltip: 'Stop waiting for the result',
                  onPressed: _c.running ? _c.cancel : null,
                ),
                const ToolbarSeparator(),
                DevToolsButton(
                  icon: Icons.history,
                  label: 'History',
                  color: _historyOpen ? theme.colorScheme.primary : null,
                  onPressed: () => setState(() => _historyOpen = !_historyOpen),
                ),
                DevToolsButton.iconOnly(
                  icon: Icons.data_array,
                  tooltip: 'Copy results as JSON',
                  onPressed: _c.result == null
                      ? null
                      : () => widget.host.copyToClipboard(_c.resultsJson(),
                          what: 'results as JSON'),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    'Reads return at most ${widget.maxSqlRows} rows · writes ask for confirmation',
                    style: theme.subtleTextStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _main(theme)),
                  if (_historyOpen)
                    SizedBox(width: 300, child: _history(theme)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _main(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 140,
          child: Semantics(
            label: 'SQL query',
            textField: true,
            child: SqlEditor(
              controller: _editor,
              focusNode: _editorFocus,
              onRun: _run,
              onChanged: (text) => _c.sql = text,
            ),
          ),
        ),
        StatusLine(children: _statusChildren(theme)),
        Expanded(child: _results()),
      ],
    );
  }

  List<Widget> _statusChildren(ThemeData theme) {
    final result = _c.result;
    if (_c.running) {
      return const [
        SizedBox(
            width: smallProgressSize,
            height: smallProgressSize,
            child: CircularProgressIndicator(strokeWidth: 1.5)),
        Text('Executing query…'),
      ];
    }
    if (_c.error != null) return [Flexible(child: ErrorText(_c.error!))];
    if (_c.notice != null) return [Text(_c.notice!)];
    if (result == null) return const [Text('Ready')];
    return [
      Icon(Icons.check_circle_outline,
          size: defaultIconSize, color: theme.colorScheme.primary),
      Text(_c.statusText),
      if (result.truncated)
        Flexible(
          child: Text(
            'Showing the first ${result.rowCount} rows — add LIMIT/OFFSET to page.',
            style: theme.regularTextStyle
                .copyWith(color: theme.colorScheme.tertiary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

  Widget _results() {
    final result = _c.result;
    if (result == null || result.kind == SqlStatementKind.write) {
      return const EmptyMessage('Results appear here.',
          icon: Icons.table_rows_outlined);
    }
    final grid = DataGrid(
      key: _gridKey,
      columns: _c.gridColumns,
      rows: result.rows,
      columnWidths: _c.columnWidths,
      onOpenCell: (row, col) => setState(() => _inspected = (row, col)),
      onSelect: (row, col) {
        if (_inspected != null) setState(() => _inspected = (row, col));
      },
      onCopyCell: (row, col) =>
          widget.host.copyToClipboard(_c.copyCellText(row, col), what: 'cell'),
      onCopyRow: (row) =>
          widget.host.copyToClipboard(_c.rowJson(row), what: 'row as JSON'),
      onContextMenu: _showMenu,
      semanticLabel: 'Query results',
      emptyMessage: 'The query returned no rows',
    );
    final inspected = _inspected;
    if (inspected == null || inspected.$1 >= result.rows.length) return grid;
    final (row, col) = inspected;
    final column = result.columns[col];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: grid),
        SizedBox(
          width: 380,
          child: ValueInspector(
            column: column.name,
            valueType: column.valueType,
            value: result.rows[row][col],
            onCopy: (text) =>
                widget.host.copyToClipboard(text, what: column.name),
            onClose: () {
              setState(() => _inspected = null);
              _gridKey.currentState?.focus();
            },
          ),
        ),
      ],
    );
  }

  void _showMenu(int row, int col, Offset position) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    unawaited(
      showMenu<VoidCallback>(
        context: context,
        position: RelativeRect.fromRect(
            position & const Size(1, 1), Offset.zero & overlay.size),
        items: [
          PopupMenuItem(
            value: () => widget.host
                .copyToClipboard(_c.copyCellText(row, col), what: 'cell'),
            child: const Text('Copy cell'),
          ),
          PopupMenuItem(
            value: () => widget.host
                .copyToClipboard(_c.rowJson(row), what: 'row as JSON'),
            child: const Text('Copy row as JSON'),
          ),
          PopupMenuItem(
            value: () => setState(() => _inspected = (row, col)),
            child: const Text('View value'),
          ),
        ],
      ).then((action) => action?.call()),
    );
  }

  Widget _history(ThemeData theme) {
    final entries = _c.entries;
    return Container(
      decoration: BoxDecoration(
          border: Border(
              left: BorderSide(color: theme.colorScheme.outlineVariant))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AreaPaneHeader(
            roundedTopBorder: false,
            includeTopBorder: false,
            title: const Text('Query history'),
            actions: [
              DevToolsButton.iconOnly(
                icon: Icons.delete_outline,
                tooltip: 'Clear history',
                outlined: false,
                onPressed: entries.isEmpty
                    ? null
                    : () => _c.history.clear(_c.database.id),
              ),
            ],
          ),
          Expanded(
            child: entries.isEmpty
                ? const EmptyMessage(
                    'Queries you run are kept here (in DevTools only).')
                : ListView.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      return Semantics(
                        button: true,
                        label: 'History entry: ${e.sql}',
                        child: InkWell(
                          onTap: () => _useHistory(e, run: false),
                          onDoubleTap: () => _useHistory(e, run: true),
                          child: Padding(
                            padding: const EdgeInsets.all(densePadding),
                            child: Row(
                              children: [
                                Icon(
                                  e.succeeded
                                      ? Icons.check
                                      : Icons.error_outline,
                                  size: defaultIconSize,
                                  color: e.succeeded
                                      ? theme.colorScheme.subtleTextColor
                                      : theme.colorScheme.error,
                                ),
                                const SizedBox(width: densePadding),
                                Expanded(
                                  child: Text(
                                    e.sql.replaceAll(RegExp(r'\s+'), ' '),
                                    style: monoStyle(theme),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                DevToolsButton.iconOnly(
                                  icon: Icons.play_arrow,
                                  tooltip: 'Run again',
                                  outlined: false,
                                  onPressed: _c.running || !widget.connected
                                      ? null
                                      : () => _useHistory(e, run: true),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

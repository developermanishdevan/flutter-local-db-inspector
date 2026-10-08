import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import '../services/host.dart';
import '../services/table_controller.dart';
import '../widgets/common.dart';
import '../widgets/data_grid.dart';
import '../widgets/row_form.dart';
import '../widgets/toolbar.dart';
import '../widgets/value_inspector.dart';

const filterOperatorLabels = {
  FilterOperator.equals: '=',
  FilterOperator.notEquals: '≠',
  FilterOperator.contains: 'contains',
  FilterOperator.startsWith: 'starts with',
  FilterOperator.endsWith: 'ends with',
  FilterOperator.greaterThan: '>',
  FilterOperator.lessThan: '<',
  FilterOperator.greaterOrEqual: '≥',
  FilterOperator.lessOrEqual: '≤',
  FilterOperator.isNull: 'is null',
  FilterOperator.isNotNull: 'is not null',
};

/// The Data tab of one table / collection / box.
///
/// Keyboard: Ctrl/Cmd+F search, Ctrl/Cmd+R (or F5) refresh, Esc closes the
/// value inspector; the grid handles the rest.
class TablePage extends StatefulWidget {
  const TablePage({
    super.key,
    required this.controller,
    required this.host,
    this.onDataChanged,
  });

  final TableController controller;
  final InspectorHost host;

  /// Called after inserts, deletes and clears (row counts changed).
  final VoidCallback? onDataChanged;

  @override
  State<TablePage> createState() => _TablePageState();
}

class _FilterDraft {
  _FilterDraft(this.column, this.operator, String text)
      : text = TextEditingController(text: text);

  String column;
  FilterOperator operator;
  final TextEditingController text;
}

class _TablePageState extends State<TablePage> {
  final _gridKey = GlobalKey<DataGridState>();
  final _searchFocus = FocusNode(debugLabel: 'search');
  (int, int)? _inspected;
  bool _filtersOpen = false;
  List<_FilterDraft> _drafts = [];

  TableController get _c => widget.controller;

  @override
  void didUpdateWidget(TablePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _inspected = null;
      _filtersOpen = false;
      _disposeDrafts();
    }
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    _disposeDrafts();
    super.dispose();
  }

  void _disposeDrafts() {
    for (final d in _drafts) {
      d.text.dispose();
    }
    _drafts = [];
  }

  void _refresh() => unawaited(_c.reload(withSchema: true));

  // ---------------------------------------------------------------------------
  // Actions

  void _copyCell(int row, int col) =>
      widget.host.copyToClipboard(_c.copyCellText(row, col), what: 'cell');

  void _copyRow(int row) => widget.host
      .copyToClipboard(_c.rowJson(row), what: '${_c.noun()} as JSON');

  Future<void> _deleteRow(int row) async {
    if (!_c.canDelete || _c.row(row)?.key == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete this ${_c.noun()}?',
      message:
          '${_c.table}: ${_c.keyLabel(row)}\n\nThis changes the running app\'s data and cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;
    if (await _c.deleteRow(row)) {
      setState(() => _inspected = null);
      widget.onDataChanged?.call();
    }
  }

  Future<void> _clearTable() async {
    final total = _c.page?.total;
    final count = total == null
        ? 'all ${_c.noun(plural: true)}'
        : '${WireValues.formatCount(total)} ${_c.noun(plural: total != 1)}';
    final confirmed = await showConfirmDialog(
      context,
      title: 'Clear ${_c.table}?',
      message: 'Delete $count from ${_c.table}? This cannot be undone.',
      confirmLabel: 'Delete all',
    );
    if (!confirmed) return;
    if (await _c.clearTable() != null) {
      setState(() => _inspected = null);
      widget.onDataChanged?.call();
    }
  }

  Future<void> _addRow([Map<String, WireValue> initial = const {}]) async {
    final inserted = await showRowForm(
      context,
      title: initial.isEmpty
          ? 'Add ${_c.noun()} to ${_c.table}'
          : 'Duplicate ${_c.noun()}',
      columns: _c.formColumns,
      initial: initial,
      onSubmit: _c.insertRow,
    );
    if (inserted) widget.onDataChanged?.call();
  }

  void _openValue(int row, int col) {
    setState(() => _inspected = (row, col));
  }

  void _showMenu(int row, int col, Offset position) {
    final grid = _gridKey.currentState;
    final noun = _c.noun();
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final items = <PopupMenuEntry<VoidCallback>>[
      PopupMenuItem(
          value: () => _copyCell(row, col),
          child: const _MenuLabel(Icons.copy, 'Copy cell', 'Ctrl/Cmd+C')),
      PopupMenuItem(
          value: () => _copyRow(row),
          child: _MenuLabel(
              Icons.data_object, 'Copy $noun as JSON', 'Ctrl/Cmd+Shift+C')),
      const PopupMenuDivider(),
      PopupMenuItem(
          value: () => _openValue(row, col),
          child: const _MenuLabel(
              Icons.visibility_outlined, 'View value', 'Space')),
      if (_c.canUpdate) ...[
        PopupMenuItem(
          enabled: _c.canEditCell(row, col),
          value: () => grid?.beginEdit(row, col),
          child: const _MenuLabel(Icons.edit_outlined, 'Edit cell', 'Enter'),
        ),
        PopupMenuItem(
          enabled: _c.canSetNull(row, col),
          value: () => unawaited(_c.setNull(row, col)),
          child: const _MenuLabel(Icons.block, 'Set NULL', null),
        ),
      ],
      if (_c.canInsert) ...[
        const PopupMenuDivider(),
        PopupMenuItem(
          value: () => unawaited(_addRow(_c.duplicateValues(row))),
          child: _MenuLabel(
              Icons.control_point_duplicate, 'Duplicate $noun', null),
        ),
      ],
      if (_c.canDelete && _c.row(row)?.key != null)
        PopupMenuItem(
          value: () => unawaited(_deleteRow(row)),
          child: _MenuLabel(Icons.delete_outline, 'Delete $noun…', 'Delete'),
        ),
    ];
    unawaited(
      showMenu<VoidCallback>(
        context: context,
        position: RelativeRect.fromRect(
            position & const Size(1, 1), Offset.zero & overlay.size),
        items: items,
      ).then((action) => action?.call()),
    );
  }

  void _toggleFilters() {
    setState(() {
      _filtersOpen = !_filtersOpen;
      if (_filtersOpen) {
        _disposeDrafts();
        final columns = _c.filterableColumns;
        _drafts = _c.filters.isNotEmpty
            ? [
                for (final f in _c.filters)
                  _FilterDraft(f.column, f.operator,
                      f.value == null ? '' : '${f.value}'),
              ]
            : [
                if (columns.isNotEmpty)
                  _FilterDraft(columns.first.name, FilterOperator.contains, '')
              ];
      }
    });
  }

  void _applyFilters() {
    _c.applyFilters([
      for (final d in _drafts)
        if (d.column.isNotEmpty)
          _c.buildFilter(d.column, d.operator, d.text.text),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): _refresh,
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): _refresh,
        const SingleActivator(LogicalKeyboardKey.f5): _refresh,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_inspected != null) {
            setState(() => _inspected = null);
            _gridKey.currentState?.focus();
          }
        },
      },
      child: FocusTraversalGroup(
        child: ListenableBuilder(
          listenable: _c,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbar(context),
              if (_filtersOpen) _filterBar(context),
              Expanded(child: _body(context)),
              _status(context),
            ],
          ),
        ),
      ),
    );
  }

  void _focusSearch() {
    if (_c.can(DbCapability.search)) _searchFocus.requestFocus();
  }

  Widget _toolbar(BuildContext context) {
    return InspectorToolbar(
      label: '${_c.table} actions',
      children: [
        if (_c.can(DbCapability.search))
          DebouncedSearchField(
            key: ValueKey('search:${_c.databaseId}:${_c.table}'),
            initialValue: _c.search,
            focusNode: _searchFocus,
            hintText: 'Search (Ctrl/Cmd+F)',
            onChanged: _c.setSearch,
          ),
        if (_c.can(DbCapability.filter))
          DevToolsButton(
            icon: Icons.filter_list,
            label:
                _c.filters.isEmpty ? 'Filter' : 'Filter (${_c.filters.length})',
            tooltip: 'Filter ${_c.noun(plural: true)}',
            color: _c.filters.isEmpty
                ? null
                : Theme.of(context).colorScheme.primary,
            onPressed: _toggleFilters,
          ),
        DevToolsButton.iconOnly(
            icon: Icons.refresh,
            tooltip: 'Refresh (Ctrl/Cmd+R)',
            onPressed: _refresh),
        if (_c.canInsert || _c.canClear) const ToolbarSeparator(),
        if (_c.canInsert)
          DevToolsButton(
            icon: Icons.add,
            label: 'Add',
            tooltip: 'Add a ${_c.noun()}',
            onPressed: _c.schema == null ? null : () => unawaited(_addRow()),
          ),
        if (_c.canClear)
          DevToolsButton.iconOnly(
            icon: Icons.delete_sweep_outlined,
            tooltip: 'Delete all ${_c.noun(plural: true)}…',
            onPressed: () => unawaited(_clearTable()),
          ),
        const Spacer(),
        Pager(
          pageIndex: _c.pageIndex,
          pageCount: _c.pageCount,
          pageSize: _c.pageSize,
          pageSizes: [
            for (final n in pageSizes)
              if (n <= _c.maxPageSize) n
          ],
          hasNext: _c.hasNextPage,
          onPage: _c.goToPage,
          onPageSize: _c.setPageSize,
        ),
      ],
    );
  }

  Widget _filterBar(BuildContext context) {
    final theme = Theme.of(context);
    final columns = _c.filterableColumns;
    return Container(
      padding: const EdgeInsets.all(densePadding),
      decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(color: theme.colorScheme.outlineVariant))),
      child: Semantics(
        label: 'Filter conditions',
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _drafts.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: densePadding),
                child: Row(
                  children: [
                    SizedBox(
                        width: 48,
                        child: Text(i == 0 ? 'Where' : 'and',
                            style: theme.subtleTextStyle)),
                    DropdownButton<String>(
                      value: columns.any((c) => c.name == _drafts[i].column)
                          ? _drafts[i].column
                          : null,
                      isDense: true,
                      hint: const Text('column'),
                      style: theme.regularTextStyle,
                      items: [
                        for (final c in columns)
                          DropdownMenuItem(value: c.name, child: Text(c.name))
                      ],
                      onChanged: (v) =>
                          setState(() => _drafts[i].column = v ?? ''),
                    ),
                    const SizedBox(width: densePadding),
                    DropdownButton<FilterOperator>(
                      value: _drafts[i].operator,
                      isDense: true,
                      style: theme.regularTextStyle,
                      items: [
                        for (final e in filterOperatorLabels.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(() =>
                          _drafts[i].operator = v ?? FilterOperator.equals),
                    ),
                    const SizedBox(width: densePadding),
                    if (!_drafts[i].operator.isUnary)
                      SizedBox(
                        width: 220,
                        height: defaultTextFieldHeight,
                        child: TextField(
                          controller: _drafts[i].text,
                          style: theme.regularTextStyle,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'value',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: densePadding, vertical: 6),
                          ),
                          onSubmitted: (_) => _applyFilters(),
                        ),
                      ),
                    DevToolsButton.iconOnly(
                      icon: Icons.close,
                      tooltip: 'Remove condition',
                      outlined: false,
                      onPressed: () =>
                          setState(() => _drafts.removeAt(i).text.dispose()),
                    ),
                  ],
                ),
              ),
            Wrap(
              spacing: densePadding,
              children: [
                DevToolsButton(
                  icon: Icons.add,
                  label: 'Add condition',
                  onPressed: columns.isEmpty
                      ? null
                      : () => setState(() => _drafts.add(_FilterDraft(
                          columns.first.name, FilterOperator.contains, ''))),
                ),
                DevToolsButton(
                    icon: Icons.check,
                    label: 'Apply',
                    elevated: true,
                    onPressed: _applyFilters),
                DevToolsButton(
                  icon: Icons.clear_all,
                  label: 'Clear filters',
                  onPressed: () {
                    setState(() {
                      _disposeDrafts();
                      _filtersOpen = false;
                    });
                    _c.applyFilters(const []);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final page = _c.page;
    if (page == null) {
      if (_c.error != null) return Center(child: ErrorText(_c.error!));
      return const Center(child: CircularProgressIndicator());
    }
    final grid = Stack(
      children: [
        DataGrid(
          key: _gridKey,
          columns: _c.gridColumns,
          rows: _c.rowValues,
          columnWidths: _c.columnWidths,
          rowOffset: _c.pageIndex * _c.pageSize,
          sort: _c.sort,
          onSort: _c.can(DbCapability.sort) ? _c.toggleSort : null,
          canEdit: _c.canEditCell,
          onCommitEdit: _c.commitEdit,
          onOpenCell: _openValue,
          onSelect: (row, col) {
            if (_inspected != null) setState(() => _inspected = (row, col));
          },
          onContextMenu: _showMenu,
          onDeleteRow:
              _c.canDelete ? (row) => unawaited(_deleteRow(row)) : null,
          onCopyCell: _copyCell,
          onCopyRow: _copyRow,
          semanticLabel: '${_c.table} data',
          emptyMessage: _c.search.isNotEmpty || _c.filters.isNotEmpty
              ? 'No matching ${_c.noun(plural: true)}'
              : 'No ${_c.noun(plural: true)}',
        ),
        if (_c.loading)
          const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(minHeight: 2)),
      ],
    );
    final inspected = _inspected;
    final record = inspected == null ? null : _c.row(inspected.$1);
    if (inspected == null ||
        record == null ||
        inspected.$2 >= page.columns.length) {
      return grid;
    }
    final (row, col) = inspected;
    final column = page.columns[col];
    final info = _c.columnInfo(column.name);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: grid),
        SizedBox(
          width: 380,
          child: ValueInspector(
            column: column.name,
            valueType: column.valueType,
            value: record.values[col],
            editable: _c.canEditValue(row, col),
            nullable: info?.nullable ?? true,
            loadFull: record.key == null
                ? null
                : (maxBytes) => _c.loadFullValue(row, col, maxBytes: maxBytes),
            onCopy: (text) =>
                widget.host.copyToClipboard(text, what: column.name),
            onSave: (value) => _c.updateValue(row, column.name, value),
            onClose: () {
              setState(() => _inspected = null);
              _gridKey.currentState?.focus();
            },
          ),
        ),
      ],
    );
  }

  Widget _status(BuildContext context) {
    final error = _c.error;
    return StatusLine(
      children: [
        if (error != null && _c.page != null)
          Flexible(child: ErrorText(error))
        else
          Flexible(child: Text(_c.statusText, overflow: TextOverflow.ellipsis)),
        if (error == null && _c.message != null) Text(_c.message!),
        if (_c.database.readOnly)
          const TagLabel('read-only',
              tooltip: 'Writes are disabled for this database', warning: true),
      ],
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.icon, this.label, this.shortcut);

  final IconData icon;
  final String label;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: defaultIconSize),
        const SizedBox(width: denseSpacing),
        Expanded(child: Text(label, style: theme.regularTextStyle)),
        if (shortcut != null) Text(shortcut!, style: theme.subtleTextStyle),
      ],
    );
  }
}

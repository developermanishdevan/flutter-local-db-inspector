import 'dart:async';
import 'dart:math' as math;

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import '../services/table_controller.dart';
import 'common.dart';

typedef CellCallback = void Function(int row, int col);

/// Dense, keyboard-driven data grid: sticky header, horizontal and vertical
/// scrolling, resizable columns, row numbers, typed cell rendering and
/// inline editing.
///
/// Keyboard: arrows move, Enter/F2 edit (or open the value), Esc cancels an
/// edit, Delete deletes the row, Ctrl/Cmd+C copies the cell and
/// Ctrl/Cmd+Shift+C the row as JSON, Shift+F10 opens the context menu.
class DataGrid extends StatefulWidget {
  const DataGrid({
    super.key,
    required this.columns,
    required this.rows,
    required this.columnWidths,
    this.rowOffset = 0,
    this.sort = const [],
    this.onSort,
    this.canEdit,
    this.onCommitEdit,
    this.onOpenCell,
    this.onSelect,
    this.onContextMenu,
    this.onDeleteRow,
    this.onCopyCell,
    this.onCopyRow,
    this.semanticLabel = 'Data',
    this.emptyMessage = 'No rows',
  });

  final List<GridColumn> columns;
  final List<List<WireValue>> rows;

  /// User-chosen widths by column name; updated in place when resizing so
  /// they survive reloads.
  final Map<String, double> columnWidths;

  /// Number of the first row minus one (page offset).
  final int rowOffset;
  final List<RowSort> sort;

  /// Header click; `null` disables sorting.
  final void Function(String column)? onSort;
  final bool Function(int row, int col)? canEdit;
  final Future<bool> Function(int row, int col, String text)? onCommitEdit;
  final CellCallback? onOpenCell;
  final CellCallback? onSelect;
  final void Function(int row, int col, Offset globalPosition)? onContextMenu;
  final void Function(int row)? onDeleteRow;
  final CellCallback? onCopyCell;
  final void Function(int row)? onCopyRow;
  final String semanticLabel;
  final String emptyMessage;

  static const rowHeight = 24.0;
  static const headerHeight = 28.0;
  static const minColumnWidth = 48.0;
  static const maxColumnWidth = 800.0;

  /// Initial width: wide enough for the header (name + type badge) and for
  /// typical values of the column's type (e.g. 13-digit epoch millis).
  static double defaultWidth(GridColumn column) {
    final base = switch (column.valueType) {
      DbValueType.integer => 120.0,
      DbValueType.real => 120.0,
      DbValueType.boolean => 80.0,
      DbValueType.dateTime => 190.0,
      DbValueType.json => 240.0,
      DbValueType.blob => 120.0,
      DbValueType.text || DbValueType.unknown || DbValueType.nullValue => 180.0,
    };
    final typeLabel = column.declaredType ?? column.valueType.wireName;
    final icons = (column.primaryKey ? 16 : 0) + (column.masked ? 16 : 0);
    final header =
        (column.name.length * 7.5) + (typeLabel.length * 6.0) + icons + 36;
    return math.max(base, header).clamp(minColumnWidth, 320.0);
  }

  @override
  State<DataGrid> createState() => DataGridState();
}

class DataGridState extends State<DataGrid> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  final _gridFocus = FocusNode(debugLabel: 'data grid');
  final _editFocus = FocusNode(debugLabel: 'cell editor');
  final _editController = TextEditingController();
  final _gridKey = GlobalKey();

  int? _row;
  int? _col;
  (int, int)? _editing;
  bool _saving = false;

  /// The selected cell, if any.
  (int, int)? get selection =>
      _row != null && _col != null ? (_row!, _col!) : null;

  bool get isEditing => _editing != null;

  @override
  void didUpdateWidget(DataGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.rows, widget.rows)) {
      _editing = null;
      _saving = false;
    }
    if (widget.rows.isEmpty || widget.columns.isEmpty) {
      _row = null;
      _col = null;
    } else if (_row != null) {
      _row = math.min(_row!, widget.rows.length - 1);
      _col = math.min(_col ?? 0, widget.columns.length - 1);
    }
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    _gridFocus.dispose();
    _editFocus.dispose();
    _editController.dispose();
    super.dispose();
  }

  /// Moves keyboard focus to the grid.
  void focus() => _gridFocus.requestFocus();

  double _width(GridColumn column) =>
      widget.columnWidths[column.name] ?? DataGrid.defaultWidth(column);

  double get _rowNumberWidth {
    final digits = '${widget.rowOffset + widget.rows.length}'.length;
    return math.max(40, 12 + digits * 8.0);
  }

  void select(int row, int col, {bool notify = true}) {
    if (widget.rows.isEmpty || widget.columns.isEmpty) return;
    final r = row.clamp(0, widget.rows.length - 1);
    final c = col.clamp(0, widget.columns.length - 1);
    setState(() {
      _row = r;
      _col = c;
    });
    _ensureVisible(r, c);
    if (notify) widget.onSelect?.call(r, c);
  }

  void _ensureVisible(int row, int col) {
    if (_vertical.hasClients) {
      final top = row * DataGrid.rowHeight;
      final viewport = _vertical.position.viewportDimension;
      final offset = _vertical.offset;
      if (top < offset) {
        _vertical.jumpTo(top);
      } else if (top + DataGrid.rowHeight > offset + viewport) {
        _vertical.jumpTo(
          math.min(
            top + DataGrid.rowHeight - viewport,
            _vertical.position.maxScrollExtent,
          ),
        );
      }
    }
    if (_horizontal.hasClients) {
      var left = _rowNumberWidth;
      for (var i = 0; i < col; i++) {
        left += _width(widget.columns[i]);
      }
      final right = left + _width(widget.columns[col]);
      final viewport = _horizontal.position.viewportDimension;
      final offset = _horizontal.offset;
      if (left - _rowNumberWidth < offset) {
        _horizontal.jumpTo(math.max(0, left - _rowNumberWidth));
      } else if (right > offset + viewport) {
        _horizontal.jumpTo(
          math.min(right - viewport, _horizontal.position.maxScrollExtent),
        );
      }
    }
  }

  /// Starts inline editing of a cell when [DataGrid.canEdit] allows it.
  bool beginEdit(int row, int col) {
    if (widget.onCommitEdit == null ||
        !(widget.canEdit?.call(row, col) ?? false)) {
      return false;
    }
    select(row, col, notify: false);
    _editController.text = WireValues.editText(widget.rows[row][col]);
    _editController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _editController.text.length,
    );
    setState(() => _editing = (row, col));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
    return true;
  }

  void _cancelEdit() {
    setState(() {
      _editing = null;
      _saving = false;
    });
    _gridFocus.requestFocus();
  }

  Future<void> _commitEdit() async {
    final editing = _editing;
    final commit = widget.onCommitEdit;
    if (editing == null || commit == null || _saving) return;
    setState(() => _saving = true);
    final ok = await commit(editing.$1, editing.$2, _editController.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _editing = null;
    });
    if (ok) {
      _gridFocus.requestFocus();
    } else {
      _editFocus.requestFocus();
    }
  }

  void _activate(int row, int col) {
    if (!beginEdit(row, col)) widget.onOpenCell?.call(row, col);
  }

  /// Global position of a cell's bottom-left corner (for keyboard menus).
  Offset _cellPosition(int row, int col) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    var x = _rowNumberWidth;
    for (var i = 0; i < col; i++) {
      x += _width(widget.columns[i]);
    }
    final y = DataGrid.headerHeight + (row + 1) * DataGrid.rowHeight;
    final scrollX = _horizontal.hasClients ? _horizontal.offset : 0.0;
    final scrollY = _vertical.hasClients ? _vertical.offset : 0.0;
    return box.localToGlobal(Offset(x - scrollX, y - scrollY));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (widget.rows.isEmpty || widget.columns.isEmpty || isEditing) {
      return KeyEventResult.ignored;
    }
    final row = _row ?? 0;
    final col = _col ?? 0;
    final key = event.logicalKey;
    final modifier = isPrimaryModifierPressed();
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (_row == null &&
        {
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        }.contains(key)) {
      select(0, 0);
      return KeyEventResult.handled;
    }
    switch (key) {
      case LogicalKeyboardKey.arrowDown:
        select(row + 1, col);
      case LogicalKeyboardKey.arrowUp:
        select(row - 1, col);
      case LogicalKeyboardKey.arrowRight:
        select(row, col + 1);
      case LogicalKeyboardKey.arrowLeft:
        select(row, col - 1);
      case LogicalKeyboardKey.home:
        select(modifier ? 0 : row, 0);
      case LogicalKeyboardKey.end:
        select(
            modifier ? widget.rows.length - 1 : row, widget.columns.length - 1);
      case LogicalKeyboardKey.pageDown:
        select(row + 10, col);
      case LogicalKeyboardKey.pageUp:
        select(row - 10, col);
      case LogicalKeyboardKey.enter ||
              LogicalKeyboardKey.numpadEnter ||
              LogicalKeyboardKey.f2
          when _row != null:
        _activate(row, col);
      case LogicalKeyboardKey.space when _row != null:
        widget.onOpenCell?.call(row, col);
      case LogicalKeyboardKey.delete
          when _row != null && widget.onDeleteRow != null:
        widget.onDeleteRow!(row);
      case LogicalKeyboardKey.keyC when modifier && _row != null:
        if (shift) {
          widget.onCopyRow?.call(row);
        } else {
          widget.onCopyCell?.call(row, col);
        }
      case LogicalKeyboardKey.f10 when shift && _row != null:
        widget.onContextMenu?.call(row, col, _cellPosition(row, col));
      case LogicalKeyboardKey.contextMenu when _row != null:
        widget.onContextMenu?.call(row, col, _cellPosition(row, col));
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: widget.semanticLabel,
      container: true,
      child: Focus(
        focusNode: _gridFocus,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          key: _gridKey,
          builder: (context, constraints) {
            final contentWidth = _rowNumberWidth +
                widget.columns.fold<double>(0, (sum, c) => sum + _width(c));
            final width = math.max(contentWidth, constraints.maxWidth);
            return Scrollbar(
              controller: _vertical,
              thumbVisibility: true,
              notificationPredicate: (n) => n.depth == 1,
              child: Scrollbar(
                controller: _horizontal,
                thumbVisibility: true,
                notificationPredicate: (n) => n.depth == 0,
                child: SingleChildScrollView(
                  controller: _horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: width,
                    height: constraints.maxHeight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _header(theme),
                        Expanded(
                          child: Stack(
                            children: [
                              ListView.builder(
                                controller: _vertical,
                                itemExtent: DataGrid.rowHeight,
                                itemCount: widget.rows.length,
                                itemBuilder: (context, i) =>
                                    _rowWidget(theme, i),
                              ),
                              if (widget.rows.isEmpty)
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  width: constraints.maxWidth,
                                  child: EmptyMessage(widget.emptyMessage),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  BorderSide _divider(ThemeData theme) =>
      BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5);

  Widget _header(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      height: DataGrid.headerHeight,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _rowNumberWidth,
            child: Semantics(
              label: 'Row number',
              child: Center(child: Text('#', style: theme.subtleTextStyle)),
            ),
          ),
          for (final column in widget.columns) _headerCell(theme, column),
        ],
      ),
    );
  }

  Widget _headerCell(ThemeData theme, GridColumn column) {
    final scheme = theme.colorScheme;
    final sort = widget.sort.where((s) => s.column == column.name).firstOrNull;
    final sortable = widget.onSort != null && !column.masked;
    final sortLabel = switch (sort?.direction) {
      SortDirection.asc => ', sorted ascending',
      SortDirection.desc => ', sorted descending',
      null => '',
    };
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: densePadding + 2),
      child: Row(
        children: [
          if (column.primaryKey)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child:
                  Icon(Icons.key, size: tableIconSize, color: scheme.tertiary),
            ),
          if (column.masked)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(Icons.lock_outline,
                  size: tableIconSize, color: scheme.subtleTextColor),
            ),
          Flexible(
            child: Text(
              column.name,
              style: theme.boldTextStyle,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: densePadding),
          Flexible(
            child: Text(
              column.typeLabel,
              style: theme.subtleTextStyle.copyWith(fontSize: smallFontSize),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          if (sort != null)
            Icon(
              sort.direction == SortDirection.asc
                  ? Icons.arrow_upward
                  : Icons.arrow_downward,
              size: tableIconSize,
              color: scheme.primary,
            ),
        ],
      ),
    );
    return SizedBox(
      width: _width(column),
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              header: true,
              button: sortable,
              label: '${column.name}, ${column.typeLabel}$sortLabel',
              excludeSemantics: true,
              child: Tooltip(
                message: sortable
                    ? '${column.name} (${column.typeLabel}) — click to sort'
                    : '${column.name} (${column.typeLabel})',
                waitDuration: const Duration(milliseconds: 600),
                child: InkWell(
                  onTap: sortable ? () => widget.onSort!(column.name) : null,
                  canRequestFocus: false,
                  child: Container(
                    decoration:
                        BoxDecoration(border: Border(right: _divider(theme))),
                    alignment: Alignment.centerLeft,
                    child: content,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 6,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (details) => setState(() {
                  widget.columnWidths[column.name] = (_width(column) +
                          details.delta.dx)
                      .clamp(DataGrid.minColumnWidth, DataGrid.maxColumnWidth);
                }),
                onDoubleTap: () =>
                    setState(() => widget.columnWidths.remove(column.name)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowWidget(ThemeData theme, int index) {
    final scheme = theme.colorScheme;
    final selectedRow = _row == index;
    final background = selectedRow
        ? scheme.selectedRowBackgroundColor
        : index.isEven
            ? scheme.alternatingBackgroundColor1
            : scheme.alternatingBackgroundColor2;
    final values = widget.rows[index];
    return ColoredBox(
      color: background,
      child: Row(
        children: [
          Container(
            width: _rowNumberWidth,
            padding: const EdgeInsets.symmetric(horizontal: densePadding),
            alignment: Alignment.centerRight,
            decoration: BoxDecoration(border: Border(right: _divider(theme))),
            child: Text(
              '${widget.rowOffset + index + 1}',
              style: monoStyle(theme).copyWith(color: scheme.subtleTextColor),
            ),
          ),
          for (var c = 0; c < widget.columns.length; c++)
            _cell(theme, index, c,
                c < values.length ? values[c] : const WireNull()),
        ],
      ),
    );
  }

  Widget _cell(ThemeData theme, int row, int col, WireValue value) {
    final column = widget.columns[col];
    final width = _width(column);
    final selected = _row == row && _col == col;
    if (_editing == (row, col)) return _editor(theme, width, column);
    final display = WireValues.display(value);
    final numeric = display.kind == CellKind.number;
    Widget text = Text(
      display.text.replaceAll('\n', '⏎'),
      style: cellStyle(theme, display.kind),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: numeric ? TextAlign.right : TextAlign.left,
    );
    if (display.tooltip != null) {
      text = Tooltip(
          message: display.tooltip,
          waitDuration: const Duration(milliseconds: 600),
          child: text);
    }
    return Semantics(
      selected: selected,
      label: '${column.name}: ${display.text}',
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (event) {
          _gridFocus.requestFocus();
          if (_row != row || _col != col) select(row, col);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () => _activate(row, col),
          onSecondaryTapUp: widget.onContextMenu == null
              ? null
              : (details) =>
                  widget.onContextMenu!(row, col, details.globalPosition),
          onLongPressStart: widget.onContextMenu == null
              ? null
              : (details) =>
                  widget.onContextMenu!(row, col, details.globalPosition),
          child: Container(
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: densePadding + 2),
            alignment: numeric ? Alignment.centerRight : Alignment.centerLeft,
            decoration: BoxDecoration(
              border: selected
                  ? Border.all(color: theme.colorScheme.primary, width: 1.5)
                  : Border(right: _divider(theme)),
            ),
            child: text,
          ),
        ),
      ),
    );
  }

  Widget _editor(ThemeData theme, double width, GridColumn column) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.primary, width: 1.5),
        color: theme.colorScheme.surface,
      ),
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _cancelEdit();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: _editController,
          focusNode: _editFocus,
          enabled: !_saving,
          style: theme.regularTextStyle,
          maxLines: 1,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: densePadding + 2, vertical: 6),
            hintText: column.typeLabel,
          ),
          onSubmitted: (_) => unawaited(_commitEdit()),
          onTapOutside: (_) {
            if (!_saving) _cancelEdit();
          },
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import 'wording.dart';

/// A column as shown by the data grid.
@immutable
class GridColumn {
  const GridColumn({
    required this.name,
    this.valueType = DbValueType.unknown,
    this.declaredType,
    this.primaryKey = false,
    this.masked = false,
  });

  final String name;
  final DbValueType valueType;
  final String? declaredType;
  final bool primaryKey;
  final bool masked;

  /// Short type label for the header.
  String get typeLabel => (declaredType?.isNotEmpty ?? false)
      ? declaredType!.toLowerCase()
      : valueType.wireName;
}

/// Page sizes offered by the pager (capped by the app's `maxPageSize`).
const pageSizes = [25, 50, 100];

/// State of the Data and Schema tabs for one table / collection / box:
/// server-side paging, search, filters, sort, editing and value reads.
class TableController extends ChangeNotifier {
  TableController({
    required this.client,
    required DatabaseDescriptor database,
    required EntitySummary entity,
    InspectorLimits limits = const InspectorLimits(),
  })  : _database = database,
        _entity = entity,
        maxPageSize = limits.maxPageSize,
        _pageSize = pageSizes.contains(limits.defaultPageSize) &&
                limits.defaultPageSize <= limits.maxPageSize
            ? limits.defaultPageSize
            : pageSizes.first;

  final InspectorClient client;
  final int maxPageSize;
  DatabaseDescriptor _database;
  EntitySummary _entity;

  DatabaseDescriptor get database => _database;
  EntitySummary get entity => _entity;

  /// Points the controller at fresh descriptors of the same table (after the
  /// app restarted or the database list was reloaded), keeping paging,
  /// search, filters and sort.
  void rebind(DatabaseDescriptor database, EntitySummary entity) {
    assert(database.id == _database.id && entity.name == _entity.name);
    _database = database;
    _entity = entity;
  }

  /// Column widths chosen by the user, kept across reloads.
  final columnWidths = <String, double>{};

  TableSchemaResult? _schema;
  RowsPageResult? _page;
  int _pageIndex = 0;
  int _pageSize;
  String _search = '';
  List<RowFilter> _filters = const [];
  List<RowSort> _sort = const [];
  bool _loading = false;
  String? _error;
  String? _message;
  Duration? _elapsed;
  int _seq = 0;
  bool _disposed = false;

  TableSchemaResult? get schema => _schema;
  RowsPageResult? get page => _page;
  int get pageIndex => _pageIndex;
  int get pageSize => _pageSize;
  String get search => _search;
  List<RowFilter> get filters => _filters;
  List<RowSort> get sort => _sort;
  bool get loading => _loading;

  /// Last error, formatted for display.
  String? get error => _error;

  /// Last success message ("Saved name"), for status lines and screen
  /// readers.
  String? get message => _message;
  Duration? get elapsed => _elapsed;

  String get databaseId => database.id;
  String get table => entity.name;

  bool can(DbCapability capability) =>
      database.capabilities.contains(capability);

  /// Whether records of this entity can be modified at all.
  bool get writable =>
      !database.readOnly &&
      !entity.readOnly &&
      entity.kind != EntityKind.view &&
      _schema?.schema.rowKey != RowKeyKind.none;

  bool get canInsert => writable && can(DbCapability.insert);
  bool get canClear => writable && can(DbCapability.clear);
  bool get canDelete => writable && can(DbCapability.delete);
  bool get canUpdate => writable && can(DbCapability.update);

  String noun({bool plural = false}) =>
      Wording.record(database.dataModel, plural: plural);

  int? get pageCount {
    final total = _page?.total;
    if (total == null) return null;
    return total == 0 ? 1 : (total + _pageSize - 1) ~/ _pageSize;
  }

  bool get hasNextPage {
    final pages = pageCount;
    if (pages == null) return (_page?.rows.length ?? 0) == _pageSize;
    return _pageIndex < pages - 1;
  }

  ColumnInfo? columnInfo(String name) => _schema?.schema.column(name);

  List<GridColumn> get gridColumns {
    final sensitive = _schema?.sensitiveColumns ?? const <String>{};
    return [
      for (final c in _page?.columns ?? const <ResultColumn>[])
        GridColumn(
          name: c.name,
          valueType: c.valueType,
          declaredType: c.declaredType ?? columnInfo(c.name)?.declaredType,
          primaryKey: columnInfo(c.name)?.isPrimaryKey ?? false,
          masked: sensitive.contains(c.name),
        ),
    ];
  }

  List<List<WireValue>> get rowValues =>
      [for (final r in _page?.rows ?? const <WireRow>[]) r.values];

  /// Columns that may be filtered (sensitive columns never are).
  List<ResultColumn> get filterableColumns {
    final sensitive = _schema?.sensitiveColumns ?? const <String>{};
    return [
      for (final c in _page?.columns ?? const <ResultColumn>[])
        if (!sensitive.contains(c.name)) c,
    ];
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Loads the current page (and the schema when [withSchema] or unknown).
  Future<void> reload({bool withSchema = false}) async {
    final seq = ++_seq;
    _loading = true;
    _error = null;
    _notify();
    try {
      if (withSchema || _schema == null) {
        final schema = await client.tableSchema(databaseId, table);
        if (seq != _seq) return;
        _schema = schema;
      }
      final watch = Stopwatch()..start();
      final page = await client.queryRows(
        databaseId,
        table,
        page: _pageIndex,
        pageSize: _pageSize,
        filters: _filters,
        sort: _sort,
        search: _search,
      );
      if (seq != _seq) return;
      final total = page.total;
      // The page fell off the end (rows were deleted): go to the last page.
      if (page.rows.isEmpty && _pageIndex > 0 && total != null) {
        _pageIndex = total == 0 ? 0 : (total - 1) ~/ _pageSize;
        _loading = false;
        return reload();
      }
      _page = page;
      _elapsed = watch.elapsed;
    } on InspectorClientException catch (e) {
      if (seq != _seq) return;
      _error = Wording.error(e);
    } finally {
      if (seq == _seq) {
        _loading = false;
        _notify();
      }
    }
  }

  /// "1–50 of 1,000 rows (filtered) · 12 ms".
  String get statusText {
    final page = _page;
    if (page == null) return _loading ? 'Loading…' : '';
    final total = page.total;
    final first = page.rows.isEmpty ? 0 : _pageIndex * _pageSize + 1;
    final last = _pageIndex * _pageSize + page.rows.length;
    final ms = _elapsed == null ? '' : ' · ${_elapsed!.inMilliseconds} ms';
    final filtered =
        _filters.isNotEmpty || _search.isNotEmpty ? ' (filtered)' : '';
    if (total == null) {
      return '${Wording.recordCount(database.dataModel, page.rows.length)}$ms';
    }
    return '${WireValues.formatCount(first)}–${WireValues.formatCount(last)} '
        'of ${Wording.recordCount(database.dataModel, total)}$filtered$ms';
  }

  void setSearch(String text) {
    final trimmed = text.trim();
    if (trimmed == _search) return;
    _search = trimmed;
    _pageIndex = 0;
    unawaited(reload());
  }

  void setPageSize(int size) {
    if (size == _pageSize) return;
    _pageSize = size;
    _pageIndex = 0;
    unawaited(reload());
  }

  void goToPage(int index) {
    final pages = pageCount;
    final clamped =
        index < 0 ? 0 : (pages != null && index >= pages ? pages - 1 : index);
    if (clamped == _pageIndex) return;
    _pageIndex = clamped;
    unawaited(reload());
  }

  /// asc → desc → none.
  void toggleSort(String column) {
    if (!can(DbCapability.sort)) return;
    final current = _sort.where((s) => s.column == column).firstOrNull;
    _sort = current == null
        ? [RowSort(column: column)]
        : current.direction == SortDirection.asc
            ? [RowSort(column: column, direction: SortDirection.desc)]
            : const [];
    _pageIndex = 0;
    unawaited(reload());
  }

  void applyFilters(List<RowFilter> filters) {
    _filters = List.unmodifiable(filters);
    _pageIndex = 0;
    unawaited(reload());
  }

  /// Builds a filter from user input, parsing [text] by column type
  /// (text operators keep the text as is).
  RowFilter buildFilter(String column, FilterOperator operator, String text) {
    if (operator.isUnary) return RowFilter(column: column, operator: operator);
    const textual = {
      FilterOperator.contains,
      FilterOperator.startsWith,
      FilterOperator.endsWith,
    };
    if (textual.contains(operator)) {
      return RowFilter(column: column, operator: operator, value: text);
    }
    final type =
        _page?.columns.where((c) => c.name == column).firstOrNull?.valueType ??
            DbValueType.text;
    return RowFilter(
      column: column,
      operator: operator,
      value: WireValues.toRaw(WireValues.parseInput(text, type)),
    );
  }

  WireRow? row(int index) {
    final rows = _page?.rows;
    if (rows == null || index < 0 || index >= rows.length) return null;
    return rows[index];
  }

  /// Whether the value inspector may edit this cell (it can load partial
  /// values first).
  bool canEditValue(int rowIndex, int col) {
    if (!canUpdate) return false;
    final record = row(rowIndex);
    final columns = _page?.columns;
    if (record?.key == null || columns == null || col >= columns.length) {
      return false;
    }
    final info = columnInfo(columns[col].name);
    if (info == null || info.generated) return false;
    if (_schema?.schema.rowKey == RowKeyKind.key && info.isPrimaryKey) {
      return false;
    }
    final value = record!.values[col];
    return !value.isMasked && value is! WireBlob;
  }

  /// Whether a cell can be edited inline (no masked, partial or binary
  /// values; never the key of a key-value store).
  bool canEditCell(int rowIndex, int col) {
    if (!canEditValue(rowIndex, col)) return false;
    final value = row(rowIndex)!.values[col];
    return WireValues.isInlineEditable(value);
  }

  /// Saves one value; reloads the page on success.
  Future<bool> updateValue(int rowIndex, String column, WireValue value) async {
    final key = row(rowIndex)?.key;
    if (key == null) return false;
    try {
      await client.updateRow(databaseId, table, key, {column: value});
      _message = 'Saved $column';
      await reload();
      return true;
    } on InspectorClientException catch (e) {
      _error = Wording.error(e);
      _notify();
      return false;
    }
  }

  /// Parses [text] by the column's type and saves it.
  Future<bool> commitEdit(int rowIndex, int col, String text) {
    final column = _page!.columns[col];
    return updateValue(
      rowIndex,
      column.name,
      WireValues.parseInput(text, column.valueType),
    );
  }

  bool canSetNull(int rowIndex, int col) {
    if (!canEditCell(rowIndex, col)) return false;
    final info = columnInfo(_page!.columns[col].name);
    return (info?.nullable ?? true) && !row(rowIndex)!.values[col].isNull;
  }

  Future<bool> setNull(int rowIndex, int col) =>
      updateValue(rowIndex, _page!.columns[col].name, const WireNull());

  Future<bool> deleteRow(int rowIndex) async {
    final key = row(rowIndex)?.key;
    if (key == null || !canDelete) return false;
    try {
      await client.deleteRow(databaseId, table, key);
      _message = 'Deleted ${noun()}';
      await reload();
      return true;
    } on InspectorClientException catch (e) {
      _error = Wording.error(e);
      _notify();
      return false;
    }
  }

  /// Inserts a record. Throws [InspectorClientException] so the form can
  /// show the error next to the fields.
  Future<void> insertRow(Map<String, WireValue> values) async {
    await client.insertRow(databaseId, table, values);
    _message = 'Inserted ${noun()}';
    await reload(withSchema: true);
  }

  /// Deletes every record; returns the number deleted, or `null` on error.
  Future<int?> clearTable() async {
    try {
      final result = await client.clearTable(databaseId, table);
      _message =
          'Deleted ${Wording.recordCount(database.dataModel, result.affectedRows)}';
      _pageIndex = 0;
      await reload(withSchema: true);
      return result.affectedRows;
    } on InspectorClientException catch (e) {
      _error = Wording.error(e);
      _notify();
      return null;
    }
  }

  /// Columns offered by the add/duplicate form.
  List<ColumnInfo> get formColumns => [
        for (final c in _schema?.schema.columns ?? const <ColumnInfo>[])
          if (!c.generated) c,
      ];

  /// Initial values to duplicate a record: keys, auto-assigned ids, masked,
  /// partial and binary values are left out.
  Map<String, WireValue> duplicateValues(int rowIndex) {
    final record = row(rowIndex);
    final columns = _page?.columns;
    if (record == null || columns == null) return const {};
    final keyed = _schema?.schema.rowKey == RowKeyKind.key;
    return {
      for (var i = 0; i < columns.length; i++)
        if (columnInfo(columns[i].name) case final info?)
          if (!info.autoIncrement &&
              !info.generated &&
              !(keyed && info.isPrimaryKey) &&
              !record.values[i].isMasked &&
              !record.values[i].isPartial &&
              record.values[i] is! WireBlob)
            columns[i].name: record.values[i],
    };
  }

  /// Streams a large value (truncated text or blob) with `value.read`.
  Future<FullValue> loadFullValue(int rowIndex, int col, {int? maxBytes}) {
    final key = row(rowIndex)?.key;
    if (key == null) {
      throw const InspectorClientException(
        ErrorCodes.rowNotFound,
        'This record cannot be addressed individually.',
      );
    }
    return client.readFullValue(
      databaseId,
      table: table,
      key: key,
      column: _page!.columns[col].name,
      maxBytes: maxBytes,
    );
  }

  String copyCellText(int rowIndex, int col) {
    final value = row(rowIndex)?.values[col];
    return value == null ? '' : WireValues.copyText(value);
  }

  /// The record as a JSON object, with exact 64-bit integers.
  String rowJson(int rowIndex) {
    final record = row(rowIndex);
    if (record == null) return '';
    return WireValues.encodeJson(
      WireValues.rowToObject(
        [for (final c in _page!.columns) c.name],
        record.values,
      ),
      indent: '  ',
    );
  }

  /// A human readable description of a record's key ("rowid = 42").
  String keyLabel(int rowIndex) {
    final key = row(rowIndex)?.key;
    if (key == null) return '';
    return key.entries
        .map(
          (e) =>
              '${e.key} = ${WireValues.copyText(WireValue.fromJson(e.value))}',
        )
        .join(', ');
  }

  void clearMessage() {
    _message = null;
    _error = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _seq++;
    super.dispose();
  }
}

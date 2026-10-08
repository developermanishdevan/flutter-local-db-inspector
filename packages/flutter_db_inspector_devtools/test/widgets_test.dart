import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:flutter_db_inspector_devtools/pages/home_page.dart';
import 'package:flutter_db_inspector_devtools/services/history_storage.dart';
import 'package:flutter_db_inspector_devtools/services/inspector_controller.dart';
import 'package:flutter_db_inspector_devtools/services/query_history.dart';
import 'package:flutter_db_inspector_devtools/services/table_controller.dart';
import 'package:flutter_db_inspector_devtools/widgets/data_grid.dart';
import 'package:flutter_db_inspector_devtools/widgets/database_tree.dart';
import 'package:flutter_db_inspector_devtools/widgets/row_form.dart';
import 'package:flutter_db_inspector_devtools/widgets/sql_editor.dart';
import 'package:flutter_db_inspector_devtools/widgets/value_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

const _columns = [
  GridColumn(name: 'id', valueType: DbValueType.integer, primaryKey: true),
  GridColumn(name: 'name', valueType: DbValueType.text),
  GridColumn(name: 'secret', valueType: DbValueType.text, masked: true),
  GridColumn(name: 'big', valueType: DbValueType.integer),
  GridColumn(name: 'data', valueType: DbValueType.blob),
  GridColumn(name: 'meta', valueType: DbValueType.json),
];

final _rows = [
  [
    const WireInt(1),
    const WireNull(),
    const WireMasked(),
    const WireBigInt('9007199254740993'),
    const WireBlob(size: 2097152, truncated: true),
    const WireJson({'a': 1}),
  ],
  [
    const WireInt(2),
    const WireString('Bob'),
    const WireMasked(),
    const WireInt(5),
    const WireNull(),
    const WireTruncatedText(preview: 'Lorem', size: 56000),
  ],
];

Future<void> _setSize(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<InspectorController> _app(
    WidgetTester tester, FakeBackend backend, FakeHost host,
    {bool dark = false}) async {
  await _setSize(tester);
  final controller = InspectorController(
    client: InspectorClient(backend),
    connection: connectedSnapshot(),
    databasesChanged: const Stream.empty(),
    history: QueryHistory(storage: MemoryHistoryStorage()),
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
      themed(HomePage(controller: controller, host: host), dark: dark));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('DataGrid', () {
    testWidgets('renders typed cells', (tester) async {
      await _setSize(tester);
      await tester.pumpWidget(
          themed(DataGrid(columns: _columns, rows: _rows, columnWidths: {})));
      expect(find.text('NULL'), findsNWidgets(2));
      expect(find.text('••••••••'), findsNWidgets(2));
      expect(find.text('9007199254740993'), findsOneWidget);
      expect(find.text('BLOB 2.0 MB'), findsOneWidget);
      expect(find.text('{"a":1}'), findsOneWidget);
      expect(find.text('Lorem…'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      // Row numbers.
      expect(find.text('1'), findsWidgets);
      expect(find.byIcon(Icons.key), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      final nullText = tester.widget<Text>(find.text('NULL').first);
      expect(nullText.style!.fontStyle, FontStyle.italic);
    });

    testWidgets('header click sorts; sort arrow shown', (tester) async {
      await _setSize(tester);
      final sorted = <String>[];
      await tester.pumpWidget(themed(DataGrid(
        columns: _columns,
        rows: _rows,
        columnWidths: {},
        sort: const [RowSort(column: 'name')],
        onSort: sorted.add,
      )));
      await tester.tap(find.text('name'));
      expect(sorted, ['name']);
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    });

    testWidgets('double-click edits, Enter commits, Esc cancels',
        (tester) async {
      await _setSize(tester);
      final commits = <(int, int, String)>[];
      await tester.pumpWidget(themed(DataGrid(
        columns: _columns,
        rows: _rows,
        columnWidths: {},
        canEdit: (r, c) => c == 1,
        onCommitEdit: (r, c, text) async {
          commits.add((r, c, text));
          return true;
        },
      )));
      await tester.tap(find.text('Bob'));
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Robert');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(commits, [(1, 1, 'Robert')]);

      // Keyboard: select, Enter starts editing, Esc cancels.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('keyboard navigation, copy, delete, open', (tester) async {
      await _setSize(tester);
      final selected = <(int, int)>[];
      final copiedCells = <(int, int)>[];
      final copiedRows = <int>[];
      final deleted = <int>[];
      final opened = <(int, int)>[];
      await tester.pumpWidget(themed(DataGrid(
        columns: _columns,
        rows: _rows,
        columnWidths: {},
        onSelect: (r, c) => selected.add((r, c)),
        onCopyCell: (r, c) => copiedCells.add((r, c)),
        onCopyRow: copiedRows.add,
        onDeleteRow: deleted.add,
        onOpenCell: (r, c) => opened.add((r, c)),
      )));
      await tester.tap(find.text('NULL').first);
      await tester.pump();
      expect(selected.last, (0, 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(selected.last, (1, 2));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(copiedCells, [(1, 2)]);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(copiedRows, [1]);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      expect(deleted, [1]);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened, [(1, 2)]); // not editable → opens the value
      await tester.pump(const Duration(seconds: 1)); // double-tap timer
    });

    testWidgets('columns resize by dragging the header edge', (tester) async {
      await _setSize(tester);
      final widths = <String, double>{};
      await tester.pumpWidget(themed(
          DataGrid(columns: _columns, rows: _rows, columnWidths: widths)));
      final header = tester.getRect(find.text('name'));
      // The handle sits on the right edge of the 180 px column.
      final cellLeft = header.left - 6;
      await tester.dragFrom(
          Offset(cellLeft + 180 - 2, header.center.dy), const Offset(60, 0));
      await tester.pump();
      expect(widths['name'], greaterThan(200));
      await tester.pump(const Duration(seconds: 1)); // double-tap timer
    });

    testWidgets('empty state', (tester) async {
      await _setSize(tester);
      await tester.pumpWidget(themed(const DataGrid(
          columns: _columns,
          rows: [],
          columnWidths: {},
          emptyMessage: 'No rows here')));
      expect(find.text('No rows here'), findsOneWidget);
    });
  });

  group('ValueInspector', () {
    testWidgets('JSON pretty/raw and copy', (tester) async {
      await _setSize(tester);
      final copied = <String>[];
      await tester.pumpWidget(themed(ValueInspector(
        column: 'meta',
        valueType: DbValueType.json,
        value: const WireJson({'a': 1}),
        onCopy: copied.add,
        onClose: () {},
      )));
      expect(find.text('{\n  "a": 1\n}'), findsOneWidget);
      await tester.tap(find.text('Raw'));
      await tester.pump();
      await tester.tap(find.text('Copy'));
      expect(copied.single, isNotEmpty);
    });

    testWidgets('loads the full value of truncated text', (tester) async {
      await _setSize(tester);
      await tester.pumpWidget(themed(ValueInspector(
        column: 'notes',
        valueType: DbValueType.text,
        value: const WireTruncatedText(preview: 'Lorem', size: 56000),
        loadFull: (max) async => FullValue(
            bytes: Uint8List.fromList('Lorem ipsum'.codeUnits),
            isText: true,
            totalBytes: 11),
        onCopy: (_) {},
        onClose: () {},
      )));
      expect(find.textContaining('Showing a preview of 55 KB'), findsOneWidget);
      await tester.tap(find.text('Load full value'));
      await tester.pumpAndSettle();
      expect(find.text('Lorem ipsum'), findsOneWidget);
    });

    testWidgets('masked values are never shown; blobs show hex',
        (tester) async {
      await _setSize(tester);
      await tester.pumpWidget(themed(ValueInspector(
        column: 'secret',
        valueType: DbValueType.text,
        value: const WireMasked(),
        onCopy: (_) {},
        onClose: () {},
      )));
      expect(find.textContaining('marked sensitive'), findsOneWidget);
      await tester.pumpWidget(themed(ValueInspector(
        column: 'data',
        valueType: DbValueType.blob,
        value: const WireBlob(size: 3, previewBase64: 'AQID'),
        onCopy: (_) {},
        onClose: () {},
      )));
      expect(find.textContaining('00000000  01 02 03'), findsOneWidget);
    });

    testWidgets('edits are parsed by value type', (tester) async {
      await _setSize(tester);
      final saved = <WireValue>[];
      await tester.pumpWidget(themed(ValueInspector(
        column: 'big',
        valueType: DbValueType.integer,
        value: const WireInt(5),
        editable: true,
        onSave: (v) async {
          saved.add(v);
          return true;
        },
        onCopy: (_) {},
        onClose: () {},
      )));
      await tester.enterText(find.byType(TextField), '9007199254740995');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set NULL'));
      await tester.pumpAndSettle();
      expect(saved, [const WireBigInt('9007199254740995'), const WireNull()]);
      expect(find.text('Saved'), findsOneWidget);
    });
  });

  testWidgets('RowForm parses values and honors NULL / auto columns',
      (tester) async {
    await _setSize(tester);
    Map<String, WireValue>? submitted;
    await tester.pumpWidget(themed(Builder(
      builder: (context) => TextButton(
        onPressed: () => unawaited(showRowForm(
          context,
          title: 'Add row',
          columns: const [
            ColumnInfo(
                name: 'id',
                valueType: DbValueType.integer,
                primaryKeyPosition: 1,
                autoIncrement: true),
            ColumnInfo(
                name: 'name', valueType: DbValueType.text, nullable: false),
            ColumnInfo(name: 'age', valueType: DbValueType.integer),
            ColumnInfo(name: 'note', valueType: DbValueType.text),
            ColumnInfo(
                name: 'calc', valueType: DbValueType.integer, generated: true),
          ],
          onSubmit: (values) async => submitted = values,
        )),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('calc'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'name'), 'Ann');
    await tester.enterText(find.widgetWithText(TextField, 'age'), '42');
    await tester.tap(find.byType(Checkbox).at(3));
    await tester.pump();
    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();
    expect(submitted, {
      'name': const WireString('Ann'),
      'age': const WireInt(42),
      'note': const WireNull(),
    });
  });

  group('Database tree', () {
    test('groups tables first, then views; indexes collapsed', () async {
      final controller = InspectorController(
        client: InspectorClient(FakeBackend()),
        connection: connectedSnapshot(),
        databasesChanged: const Stream.empty(),
        history: QueryHistory(storage: MemoryHistoryStorage()),
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final items = buildTreeItems(controller);
      expect(
        [for (final i in items) i.label],
        [
          'app_database',
          'Tables',
          'users',
          'Views',
          'active_users',
          'Indexes',
          'prefs',
          'Stores',
          'prefs'
        ],
      );
      expect(items[2].detail, '60');
      controller.setExpanded('db:app:group:Indexes', expanded: true);
      expect(buildTreeItems(controller).map((i) => i.label),
          contains('idx_users_name'));
    });

    test('filters by table name, expanding matches', () async {
      final controller = InspectorController(
        client: InspectorClient(FakeBackend()),
        connection: connectedSnapshot(),
        databasesChanged: const Stream.empty(),
        history: QueryHistory(storage: MemoryHistoryStorage()),
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Collapsed groups are expanded while filtering.
      controller.setExpanded('db:app', expanded: false);

      final labels = [
        for (final i in buildTreeItems(controller, filter: 'USER')) i.label
      ];
      expect(labels, [
        'app_database',
        'Tables',
        'users',
        'Views',
        'active_users',
        'Indexes',
        'idx_users_name',
        'prefs',
        'No names match "USER"',
      ]);

      final none = buildTreeItems(controller, filter: 'zzz');
      expect(none.where((i) => i.type == TreeItemType.entity), isEmpty);
      expect(
        none.map((i) => i.label),
        contains('No names match "zzz"'),
      );

      // Clearing the filter restores the user's own expansion state.
      expect(
        buildTreeItems(controller).map((i) => i.label),
        isNot(contains('users')),
      );
    });

    testWidgets('filter field narrows the sidebar', (tester) async {
      final backend = FakeBackend();
      final host = FakeHost();
      await _app(tester, backend, host);
      expect(find.text('active_users'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, 'Filter tables…'), 'active');
      await tester.pumpAndSettle();
      expect(find.text('active_users'), findsOneWidget);
      expect(find.text('users'), findsNothing);
      await tester.tap(find.byTooltip('Clear filter'));
      await tester.pumpAndSettle();
      expect(find.text('users'), findsWidgets);
    });
  });

  group('App', () {
    testWidgets('browse, select, inspect, delete with confirmation',
        (tester) async {
      final backend = FakeBackend();
      final host = FakeHost();
      final controller = await _app(tester, backend, host);
      expect(find.text('DATABASES'), findsOneWidget);
      expect(find.text('app_database'), findsWidgets);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('SQL'), findsOneWidget);

      await tester.tap(find.text('users'));
      await tester.pumpAndSettle();
      expect(controller.selectedEntityName, 'users');
      expect(find.text('User 2'), findsOneWidget);
      expect(find.textContaining('1–50 of 60 rows'), findsOneWidget);

      // Context menu → delete → confirm.
      await tester.tap(find.text('User 2'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Copy row as JSON'), findsOneWidget);
      await tester.tap(find.text('Delete row…'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this row?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(backend.calls(Methods.rowDelete), hasLength(1));
      expect(find.text('User 2'), findsNothing);

      // Copy cell with the keyboard.
      await tester.tap(find.text('User 3'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(host.copied.last, 'User 3');

      // Open the value inspector with Space; Esc closes it.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byType(ValueInspector), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ValueInspector), findsNothing);
    });

    testWidgets('schema, SQL with write confirmation, statistics',
        (tester) async {
      final backend = FakeBackend();
      final controller = await _app(tester, backend, FakeHost());
      controller.selectEntity('app', 'users');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Schema'));
      await tester.pumpAndSettle();
      expect(find.text('8 columns'), findsOneWidget);
      expect(find.text('CREATE INDEX'), findsOneWidget);

      await tester.tap(find.text('SQL'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.descendant(
              of: find.byType(SqlEditor), matching: find.byType(TextField)),
          'DELETE FROM users');
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'This query may modify application data.\n\nDELETE FROM users'),
          findsOneWidget);
      await tester.tap(find.text('Execute'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 rows affected'), findsOneWidget);

      await tester.enterText(
          find.descendant(
              of: find.byType(SqlEditor), matching: find.byType(TextField)),
          'SELECT big FROM users');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('9007199254740993'), findsOneWidget);
      expect(find.textContaining('add LIMIT/OFFSET'), findsOneWidget);

      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('SELECT big FROM users'), findsWidgets);

      await tester.tap(find.text('Statistics'));
      await tester.pumpAndSettle();
      expect(find.text('8.0 KB'), findsOneWidget);
      expect(find.textContaining('SQLite'), findsOneWidget);
    });

    testWidgets('read-only database hides writes; dark theme renders',
        (tester) async {
      final backend = FakeBackend(
          readOnly: true,
          capabilities: ['read', 'sort', 'update', 'delete', 'insert']);
      final controller = await _app(tester, backend, FakeHost(), dark: true);
      controller.selectEntity('app', 'users');
      await tester.pumpAndSettle();
      expect(find.text('read-only'), findsWidgets);
      expect(find.text('Add'), findsNothing);
      expect(find.text('SQL'), findsNothing);
      expect(find.byTooltip('Search (Ctrl/Cmd+F)'), findsNothing);
    });

    testWidgets('disconnected banner', (tester) async {
      await _setSize(tester);
      final controller = InspectorController(
        client: InspectorClient(FakeBackend()),
        connection: ValueNotifier(const ConnectionSnapshot(
          state: InspectorConnectionState.disconnected,
          message: 'The app stopped.',
        )),
        databasesChanged: const Stream.empty(),
        history: QueryHistory(storage: MemoryHistoryStorage()),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
          themed(HomePage(controller: controller, host: FakeHost())));
      await tester.pumpAndSettle();
      expect(find.text('The app stopped.'), findsWidgets);
      expect(find.text('Disconnected'), findsOneWidget);
    });
  });
}

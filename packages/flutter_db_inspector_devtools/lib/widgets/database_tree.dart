import 'dart:math' as math;

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import '../services/inspector_controller.dart';
import '../services/wording.dart';
import 'common.dart';

enum TreeItemType { database, group, entity, tableIndex, trigger, message }

/// One visible row of the sidebar tree.
@immutable
class TreeItem {
  const TreeItem({
    required this.type,
    required this.key,
    required this.label,
    required this.depth,
    required this.databaseId,
    this.detail,
    this.icon,
    this.expandable = false,
    this.expanded = false,
    this.readOnly = false,
    this.entity,
    this.table,
    this.isError = false,
  });

  final TreeItemType type;

  /// Stable key (also the expansion key).
  final String key;
  final String label;
  final String? detail;
  final IconData? icon;
  final int depth;
  final String databaseId;
  final bool expandable;
  final bool expanded;
  final bool readOnly;
  final EntitySummary? entity;

  /// Table an index/trigger belongs to.
  final String? table;
  final bool isError;
}

IconData entityIcon(EntityKind kind) => switch (kind) {
      EntityKind.table => Icons.table_chart_outlined,
      EntityKind.view => Icons.visibility_outlined,
      EntityKind.collection => Icons.data_object,
      EntityKind.box => Icons.inventory_2_outlined,
      EntityKind.store => Icons.folder_outlined,
    };

/// Flattens the database → group → entity hierarchy into visible rows.
///
/// A non-empty [filter] keeps only tables/collections/boxes, indexes and
/// triggers whose name contains it (case-insensitive) and expands everything
/// so every match is visible.
List<TreeItem> buildTreeItems(InspectorController controller,
    {String filter = ''}) {
  final needle = filter.trim().toLowerCase();
  final filtering = needle.isNotEmpty;
  bool matches(String name) =>
      !filtering || name.toLowerCase().contains(needle);

  final items = <TreeItem>[];
  for (final db in controller.databases) {
    final d = db.descriptor;
    final dbKey = 'db:${d.id}';
    final dbExpanded = filtering || controller.isExpanded(dbKey);
    items.add(
      TreeItem(
        type: TreeItemType.database,
        key: dbKey,
        label: d.name,
        detail: d.type,
        icon: Icons.storage,
        depth: 0,
        databaseId: d.id,
        expandable: true,
        expanded: dbExpanded,
        readOnly: d.readOnly,
      ),
    );
    if (!dbExpanded) continue;
    final overview = db.overview;
    if (overview == null) {
      items.add(
        TreeItem(
          type: TreeItemType.message,
          key: '$dbKey:status',
          label: db.error ?? (db.loading ? 'Loading…' : 'Not loaded'),
          depth: 1,
          databaseId: d.id,
          isError: db.error != null,
        ),
      );
      continue;
    }
    if (overview.entities.isEmpty) {
      items.add(
        TreeItem(
          type: TreeItemType.message,
          key: '$dbKey:empty',
          label: 'No ${Wording.entities(d.dataModel).toLowerCase()}',
          depth: 1,
          databaseId: d.id,
        ),
      );
    }
    final countBefore = items.length;
    for (final kind in Wording.groupOrder) {
      final entities = [
        for (final e in overview.entities)
          if (e.kind == kind && matches(e.name)) e,
      ];
      if (entities.isEmpty) continue;
      final groupKey = '$dbKey:group:${kind.name}';
      final expanded = filtering || controller.isExpanded(groupKey);
      items.add(
        TreeItem(
          type: TreeItemType.group,
          key: groupKey,
          label: Wording.group(kind),
          detail: '${entities.length}',
          depth: 1,
          databaseId: d.id,
          expandable: true,
          expanded: expanded,
        ),
      );
      if (!expanded) continue;
      for (final e in entities) {
        items.add(
          TreeItem(
            type: TreeItemType.entity,
            key: '$dbKey:entity:${e.name}',
            label: e.name,
            detail:
                e.rowCount == null ? null : WireValues.formatCount(e.rowCount),
            icon: entityIcon(e.kind),
            depth: 2,
            databaseId: d.id,
            entity: e,
            readOnly: e.readOnly && e.kind != EntityKind.view,
          ),
        );
      }
    }
    void addSecondary(String name, List<(String, String)> children,
        TreeItemType type, IconData icon) {
      if (children.isEmpty) return;
      final key = '$dbKey:group:$name';
      final expanded =
          filtering || controller.isExpanded(key, byDefault: false);
      items.add(
        TreeItem(
          type: TreeItemType.group,
          key: key,
          label: name,
          detail: '${children.length}',
          depth: 1,
          databaseId: d.id,
          expandable: true,
          expanded: expanded,
        ),
      );
      if (!expanded) return;
      for (final (label, table) in children) {
        items.add(
          TreeItem(
            type: type,
            key: '$key:$label',
            label: label,
            detail: table,
            icon: icon,
            depth: 2,
            databaseId: d.id,
            table: table,
          ),
        );
      }
    }

    addSecondary(
      'Indexes',
      [
        for (final i in overview.indexes)
          if (matches(i.name)) (i.name, i.table),
      ],
      TreeItemType.tableIndex,
      Icons.sort,
    );
    addSecondary(
      'Triggers',
      [
        for (final t in overview.triggers)
          if (matches(t.name)) (t.name, t.table),
      ],
      TreeItemType.trigger,
      Icons.flash_on_outlined,
    );
    if (filtering &&
        items.length == countBefore &&
        overview.entities.isNotEmpty) {
      items.add(
        TreeItem(
          type: TreeItemType.message,
          key: '$dbKey:nomatch',
          label: 'No names match "${filter.trim()}"',
          depth: 1,
          databaseId: d.id,
        ),
      );
    }
  }
  return items;
}

/// Sidebar tree: DATABASES ▸ database ▸ Tables/Views/Collections/Boxes/
/// Stores ▸ entities (with row counts), plus Indexes and Triggers.
///
/// Keyboard: Up/Down move, Right/Left expand/collapse, Enter/Space open.
class DatabaseTree extends StatefulWidget {
  const DatabaseTree({super.key, required this.controller});

  final InspectorController controller;

  static const rowHeight = 22.0;

  @override
  State<DatabaseTree> createState() => _DatabaseTreeState();
}

class _DatabaseTreeState extends State<DatabaseTree> {
  final _focus = FocusNode(debugLabel: 'database tree');
  final _scroll = ScrollController();
  final _filter = TextEditingController();
  int _cursor = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    _filter.dispose();
    super.dispose();
  }

  InspectorController get _c => widget.controller;

  bool _isSelected(TreeItem item) => switch (item.type) {
        TreeItemType.database => _c.selectedDatabase?.id == item.databaseId &&
            _c.selectedEntityName == null,
        TreeItemType.entity => _c.selectedDatabase?.id == item.databaseId &&
            _c.selectedEntityName == item.entity?.name,
        _ => false,
      };

  void _toggle(TreeItem item, {bool? expanded}) {
    if (!item.expandable) return;
    _c.setExpanded(item.key, expanded: expanded ?? !item.expanded);
  }

  void _activate(TreeItem item) {
    switch (item.type) {
      case TreeItemType.database:
        _c.selectDatabase(item.databaseId);
      case TreeItemType.group:
        _toggle(item);
      case TreeItemType.entity:
        _c.selectEntity(item.databaseId, item.entity!.name);
      case TreeItemType.tableIndex || TreeItemType.trigger:
        final table = item.table;
        if (table != null) {
          _c.selectEntity(item.databaseId, table, tab: InspectorTab.schema);
        }
      case TreeItemType.message:
        break;
    }
  }

  void _moveCursor(int index, int count) {
    if (count == 0) return;
    setState(() => _cursor = index.clamp(0, count - 1));
    if (!_scroll.hasClients) return;
    final top = _cursor * DatabaseTree.rowHeight;
    final viewport = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + DatabaseTree.rowHeight > _scroll.offset + viewport) {
      _scroll.jumpTo(math.min(top + DatabaseTree.rowHeight - viewport,
          _scroll.position.maxScrollExtent));
    }
  }

  KeyEventResult _onKey(List<TreeItem> items, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (items.isEmpty) return KeyEventResult.ignored;
    final cursor = _cursor.clamp(0, items.length - 1);
    final item = items[cursor];
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveCursor(cursor + 1, items.length);
      case LogicalKeyboardKey.arrowUp:
        _moveCursor(cursor - 1, items.length);
      case LogicalKeyboardKey.home:
        _moveCursor(0, items.length);
      case LogicalKeyboardKey.end:
        _moveCursor(items.length - 1, items.length);
      case LogicalKeyboardKey.arrowRight:
        if (item.expandable && !item.expanded) {
          _toggle(item, expanded: true);
        } else if (item.expandable) {
          _moveCursor(cursor + 1, items.length);
        }
      case LogicalKeyboardKey.arrowLeft:
        if (item.expandable && item.expanded) {
          _toggle(item, expanded: false);
        } else {
          // Go to the parent.
          for (var i = cursor - 1; i >= 0; i--) {
            if (items[i].depth < item.depth) {
              _moveCursor(i, items.length);
              break;
            }
          }
        }
      case LogicalKeyboardKey.enter ||
            LogicalKeyboardKey.numpadEnter ||
            LogicalKeyboardKey.space:
        _activate(item);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final items = buildTreeItems(_c, filter: _filter.text);
    if (items.isEmpty && _filter.text.trim().isEmpty) {
      return EmptyMessage(
        _c.isConnected
            ? (_c.loadingDatabases
                ? 'Loading databases…'
                : _c.databasesError ??
                    'No databases registered. Call DbInspector.registerDatabase() in your app.')
            : 'Not connected',
        icon: Icons.storage,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              densePadding, 0, densePadding, densePadding),
          child: SizedBox(
            height: defaultTextFieldHeight,
            child: TextField(
              controller: _filter,
              style: Theme.of(context).regularTextStyle,
              onChanged: (_) => setState(() => _cursor = 0),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter tables…',
                prefixIcon:
                    const Icon(Icons.filter_list, size: defaultIconSize),
                prefixIconConstraints: const BoxConstraints(minWidth: 28),
                suffixIcon: _filter.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear filter',
                        iconSize: defaultIconSize,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(_filter.clear),
                      ),
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: densePadding),
              ),
            ),
          ),
        ),
        Expanded(
          child: Semantics(
            label: 'Databases',
            container: true,
            child: Focus(
              focusNode: _focus,
              onKeyEvent: (_, event) => _onKey(items, event),
              child: ListView.builder(
                controller: _scroll,
                itemExtent: DatabaseTree.rowHeight,
                itemCount: items.length,
                itemBuilder: (context, i) => _row(context, items[i], i),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, TreeItem item, int index) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = _isSelected(item);
    final focused = _focus.hasFocus && index == _cursor;
    final labelStyle = switch (item.type) {
      TreeItemType.group => theme.subtleTextStyle,
      TreeItemType.database => theme.boldTextStyle,
      TreeItemType.message =>
        item.isError ? theme.errorTextStyle : theme.subtleTextStyle,
      _ => theme.regularTextStyle,
    };
    final semantics = [
      item.label,
      switch (item.type) {
        TreeItemType.database => 'database, ${item.detail}',
        TreeItemType.entity =>
          '${item.entity!.kind.name}${item.detail == null ? '' : ', ${item.detail} records'}',
        TreeItemType.group => '${item.detail} items',
        TreeItemType.tableIndex => 'index on ${item.table}',
        TreeItemType.trigger => 'trigger on ${item.table}',
        TreeItemType.message => '',
      },
      if (item.readOnly) 'read-only',
    ].where((s) => s.isNotEmpty).join(', ');
    return Semantics(
      label: semantics,
      selected: selected,
      button: item.type != TreeItemType.message,
      expanded: item.expandable ? item.expanded : null,
      excludeSemantics: true,
      onTap: () => _activate(item),
      child: InkWell(
        canRequestFocus: false,
        onTap: () {
          _focus.requestFocus();
          setState(() => _cursor = index);
          _activate(item);
        },
        onDoubleTap:
            item.type == TreeItemType.database ? () => _toggle(item) : null,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? scheme.selectedRowBackgroundColor : null,
            border: focused ? Border.all(color: scheme.primary) : null,
          ),
          padding: EdgeInsets.only(
              left: densePadding + item.depth * 14.0, right: denseSpacing),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: item.expandable
                    ? InkWell(
                        canRequestFocus: false,
                        onTap: () => _toggle(item),
                        child: Icon(
                          item.expanded
                              ? Icons.expand_more
                              : Icons.chevron_right,
                          size: defaultIconSize + 2,
                          color: scheme.subtleTextColor,
                        ),
                      )
                    : null,
              ),
              if (item.icon != null) ...[
                Icon(item.icon,
                    size: defaultIconSize,
                    color: item.type == TreeItemType.database
                        ? scheme.primary
                        : scheme.onSurfaceVariant),
                const SizedBox(width: densePadding + 2),
              ],
              // One expanding region for the label and its badges keeps the
              // trailing counts aligned in a single column.
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(item.label,
                          style: labelStyle,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1),
                    ),
                    if (item.type == TreeItemType.database &&
                        item.detail != null) ...[
                      const SizedBox(width: densePadding),
                      Text(item.detail!, style: theme.subtleTextStyle),
                    ],
                    if (item.readOnly) ...[
                      const SizedBox(width: densePadding),
                      const TagLabel('read-only',
                          tooltip: 'Writes are disabled', warning: true),
                    ],
                  ],
                ),
              ),
              if (item.type != TreeItemType.database && item.detail != null)
                Text(item.detail!, style: theme.subtleTextStyle),
            ],
          ),
        ),
      ),
    );
  }
}

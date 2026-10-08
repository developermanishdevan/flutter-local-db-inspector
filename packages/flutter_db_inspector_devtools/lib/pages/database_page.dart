import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import '../services/host.dart';
import '../services/inspector_controller.dart';
import '../services/wording.dart';
import '../widgets/common.dart';
import '../widgets/database_tree.dart';
import 'query_page.dart';
import 'schema_page.dart';
import 'stats_page.dart';
import 'table_page.dart';

/// Main area for the selected database: header and the
/// Data | Schema | SQL | Statistics tabs (SQL only with the `sql`
/// capability).
class DatabasePage extends StatelessWidget {
  const DatabasePage({super.key, required this.controller, required this.host});

  final InspectorController controller;
  final InspectorHost host;

  static String tabLabel(InspectorTab tab) => switch (tab) {
        InspectorTab.data => 'Data',
        InspectorTab.schema => 'Schema',
        InspectorTab.sql => 'SQL',
        InspectorTab.stats => 'Statistics',
      };

  @override
  Widget build(BuildContext context) {
    final db = controller.selectedDatabase;
    if (db == null) {
      return const EmptyMessage('Select a database in the tree.',
          icon: Icons.storage);
    }
    final d = db.descriptor;
    final tabs = [
      InspectorTab.data,
      InspectorTab.schema,
      if (d.capabilities.contains(DbCapability.sql)) InspectorTab.sql,
      InspectorTab.stats,
    ];
    final tab =
        tabs.contains(controller.tab) ? controller.tab : InspectorTab.data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, db),
        Expanded(child: _content(context, db, tab)),
      ],
    );
  }

  Widget _header(BuildContext context, DatabaseNode db) {
    final theme = Theme.of(context);
    final d = db.descriptor;
    final entity = controller.selectedEntity;
    final tabs = [
      InspectorTab.data,
      InspectorTab.schema,
      if (d.capabilities.contains(DbCapability.sql)) InspectorTab.sql,
      InspectorTab.stats,
    ];
    return Container(
      height: defaultHeaderHeight + densePadding * 2,
      padding: const EdgeInsets.symmetric(horizontal: denseSpacing),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(entity == null ? Icons.storage : entityIcon(entity.kind),
              size: defaultIconSize + 2),
          const SizedBox(width: densePadding),
          Flexible(
            child: Semantics(
              header: true,
              child: Text(
                entity == null ? d.name : '${d.name} › ${entity.name}',
                style: theme.boldTextStyle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: densePadding),
          TagLabel(entity?.kind.name ?? d.type,
              tooltip: 'Engine: ${d.type} · ${d.dataModel.name}'),
          if (d.readOnly) ...[
            const SizedBox(width: densePadding),
            const TagLabel('read-only',
                tooltip: 'Writes are disabled for this database',
                warning: true),
          ],
          const SizedBox(width: defaultSpacing),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Semantics(
                container: true,
                label: 'Tabs',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final t in tabs)
                      _TabButton(tab: t, controller: controller)
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, DatabaseNode db, InspectorTab tab) {
    final d = db.descriptor;
    switch (tab) {
      case InspectorTab.data:
        final table = controller.table;
        if (table == null) {
          return EmptyMessage(
            'Select one of the ${Wording.entities(d.dataModel).toLowerCase()} in the tree to browse its '
            '${Wording.record(d.dataModel, plural: true)}.',
            icon: Icons.table_chart_outlined,
          );
        }
        return TablePage(
          key: ValueKey('data:${table.databaseId}:${table.table}'),
          controller: table,
          host: host,
          onDataChanged: () => unawaited(controller.refreshDatabase(d.id)),
        );
      case InspectorTab.schema:
        return SchemaPage(controller: controller, host: host);
      case InspectorTab.sql:
        return QueryPage(
          key: ValueKey('sql:${d.id}'),
          controller: controller.sqlController(d),
          host: host,
          maxSqlRows: controller.limits.maxSqlRows,
          connected: controller.isConnected,
        );
      case InspectorTab.stats:
        return StatsPage(
          key: ValueKey('stats:${d.id}'),
          client: controller.client,
          database: d,
          generation: controller.generation,
          onOpenEntity: (name) =>
              controller.selectEntity(d.id, name, tab: InspectorTab.data),
        );
    }
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.tab, required this.controller});

  final InspectorTab tab;
  final InspectorController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = controller.tab == tab;
    final label = DatabasePage.tabLabel(tab);
    return Semantics(
      selected: selected,
      button: true,
      label: '$label tab',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => controller.setTab(tab),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: denseSpacing, vertical: densePadding),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color:
                    selected ? theme.colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: selected ? theme.boldTextStyle : theme.regularTextStyle,
          ),
        ),
      ),
    );
  }
}

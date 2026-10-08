import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import '../services/wording.dart';
import 'common.dart';

/// A dense, static table (schema sections, statistics).
class StaticTable extends StatelessWidget {
  const StaticTable({
    super.key,
    required this.headers,
    required this.rows,
    this.label,
    this.flex,
  });

  final List<String> headers;
  final List<List<Widget>> rows;
  final String? label;
  final List<int>? flex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final border = BorderSide(color: scheme.outlineVariant, width: 0.5);
    Widget row(List<Widget> cells, {bool header = false, int index = 0}) =>
        Container(
          constraints: const BoxConstraints(minHeight: 24),
          decoration: BoxDecoration(
            color: header
                ? scheme.surfaceContainerHigh
                : index.isEven
                    ? scheme.alternatingBackgroundColor1
                    : scheme.alternatingBackgroundColor2,
            border: Border(bottom: border),
          ),
          child: Row(
            children: [
              for (var i = 0; i < cells.length; i++)
                Expanded(
                  flex: flex == null ? 1 : flex![i],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: densePadding + 2, vertical: 3),
                    child: cells[i],
                  ),
                ),
            ],
          ),
        );
    return Semantics(
      label: label,
      container: true,
      child: DecoratedBox(
        decoration:
            BoxDecoration(border: Border.all(color: scheme.outlineVariant)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row(
              [
                for (final h in headers)
                  Semantics(
                      header: true, child: Text(h, style: theme.boldTextStyle)),
              ],
              header: true,
            ),
            for (var i = 0; i < rows.length; i++) row(rows[i], index: i),
          ],
        ),
      ),
    );
  }
}

/// A titled section.
class SchemaSection extends StatelessWidget {
  const SchemaSection(
      {super.key,
      required this.title,
      required this.child,
      this.actions = const []});

  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: defaultSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Semantics(
                  header: true,
                  child: Text(title, style: theme.textTheme.titleSmall)),
              const Spacer(),
              ...actions,
            ],
          ),
          const SizedBox(height: densePadding),
          child,
        ],
      ),
    );
  }
}

/// Schema of one entity: columns, foreign keys, indexes, triggers, DDL.
class SchemaView extends StatelessWidget {
  const SchemaView({
    super.key,
    required this.result,
    required this.dataModel,
    required this.onCopy,
    this.onOpenTable,
  });

  final TableSchemaResult result;
  final DbDataModel dataModel;
  final void Function(String text) onCopy;

  /// Opens a referenced table (foreign keys).
  final void Function(String table)? onOpenTable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final schema = result.schema;
    final mono = monoStyle(theme);
    Widget text(String s, {TextStyle? style}) =>
        Text(s, style: style ?? theme.regularTextStyle);
    final rowKey = switch (schema.rowKey) {
      RowKeyKind.rowid => 'Rows are addressed by rowid.',
      RowKeyKind.primaryKey => 'Rows are addressed by the primary key.',
      RowKeyKind.key => 'Records are addressed by their key.',
      RowKeyKind.none =>
        'Records cannot be addressed individually (read-only).',
    };
    return ListView(
      padding: const EdgeInsets.all(denseSpacing),
      children: [
        SchemaSection(
          title: '${schema.columns.length} ${Wording.fields(dataModel)}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StaticTable(
                label: 'Columns',
                headers: const [
                  'Column',
                  'Type',
                  'Value type',
                  'PK',
                  'Nullable',
                  'Default',
                  'Notes'
                ],
                flex: const [3, 2, 2, 1, 1, 2, 2],
                rows: [
                  for (final c in schema.columns)
                    [
                      Row(
                        children: [
                          if (c.isPrimaryKey)
                            Padding(
                              padding: const EdgeInsets.only(right: 2),
                              child: Icon(Icons.key,
                                  size: tableIconSize,
                                  color: theme.colorScheme.tertiary),
                            ),
                          Flexible(child: text(c.name)),
                        ],
                      ),
                      text(c.declaredType, style: mono),
                      text(c.valueType.wireName),
                      text(c.isPrimaryKey ? '${c.primaryKeyPosition}' : ''),
                      text(c.nullable ? 'Yes' : 'No'),
                      text(c.defaultValue ?? '', style: mono),
                      text(
                        [
                          if (c.autoIncrement) 'auto',
                          if (c.generated) 'generated',
                          if (result.sensitiveColumns.contains(c.name))
                            'masked',
                        ].join(', '),
                        style: theme.subtleTextStyle,
                      ),
                    ],
                ],
              ),
              const SizedBox(height: densePadding),
              Text(rowKey, style: theme.subtleTextStyle),
            ],
          ),
        ),
        if (schema.foreignKeys.isNotEmpty)
          SchemaSection(
            title: 'Foreign keys',
            child: StaticTable(
              label: 'Foreign keys',
              headers: const [
                'Columns',
                'References',
                'On update',
                'On delete'
              ],
              rows: [
                for (final f in schema.foreignKeys)
                  [
                    text(f.columns.join(', ')),
                    onOpenTable == null
                        ? text(
                            '${f.referencedTable}(${f.referencedColumns.join(', ')})')
                        : InkWell(
                            onTap: () => onOpenTable!(f.referencedTable),
                            child: Text(
                              '${f.referencedTable}(${f.referencedColumns.join(', ')})',
                              style: theme.linkTextStyle,
                            ),
                          ),
                    text(f.onUpdate),
                    text(f.onDelete),
                  ],
              ],
            ),
          ),
        if (schema.indexes.isNotEmpty)
          SchemaSection(
            title: 'Indexes',
            child: StaticTable(
              label: 'Indexes',
              headers: const ['Index', 'Columns', 'Unique', 'Origin'],
              rows: [
                for (final i in schema.indexes)
                  [
                    Tooltip(message: i.sql ?? '', child: text(i.name)),
                    text(i.columns.join(', ')),
                    text(i.unique ? '✓' : ''),
                    text(switch (i.origin) {
                      'pk' => 'primary key',
                      'u' => 'UNIQUE constraint',
                      'c' => 'CREATE INDEX',
                      final o => o ?? '',
                    }),
                  ],
              ],
            ),
          ),
        if (schema.triggers.isNotEmpty)
          SchemaSection(
            title: 'Triggers',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final t in schema.triggers)
                  ExpansionTile(
                    dense: true,
                    tilePadding: EdgeInsets.zero,
                    title: Text(t.name, style: theme.regularTextStyle),
                    children: [
                      Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(t.sql ?? '', style: mono)),
                    ],
                  ),
              ],
            ),
          ),
        if (schema.sql != null)
          SchemaSection(
            title: 'Definition',
            actions: [
              DevToolsButton(
                  icon: Icons.copy,
                  label: 'Copy',
                  onPressed: () => onCopy(schema.sql!)),
            ],
            child: Container(
              padding: const EdgeInsets.all(denseSpacing),
              decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outlineVariant)),
              child: SelectableText(schema.sql!, style: mono),
            ),
          ),
      ],
    );
  }
}

/// Database-level schema overview (no entity selected).
class SchemaOverviewView extends StatelessWidget {
  const SchemaOverviewView({
    super.key,
    required this.overview,
    required this.dataModel,
    required this.onOpenEntity,
  });

  final SchemaOverview overview;
  final DbDataModel dataModel;
  final void Function(String entity) onOpenEntity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = monoStyle(theme);
    return ListView(
      padding: const EdgeInsets.all(denseSpacing),
      children: [
        SchemaSection(
          title:
              '${overview.entities.length} ${Wording.entities(dataModel).toLowerCase()}',
          child: StaticTable(
            label: Wording.entities(dataModel),
            headers: [
              'Name',
              'Kind',
              _capitalize(Wording.record(dataModel, plural: true))
            ],
            rows: [
              for (final e in overview.entities)
                [
                  InkWell(
                      onTap: () => onOpenEntity(e.name),
                      child: Text(e.name, style: theme.linkTextStyle)),
                  Text(e.kind.name, style: theme.regularTextStyle),
                  Text(
                      e.rowCount == null
                          ? '—'
                          : WireValues.formatCount(e.rowCount),
                      style: theme.regularTextStyle),
                ],
            ],
          ),
        ),
        if (overview.indexes.isNotEmpty)
          SchemaSection(
            title: 'Indexes',
            child: StaticTable(
              label: 'Indexes',
              headers: const ['Index', 'Table', 'Columns', 'Unique'],
              rows: [
                for (final i in overview.indexes)
                  [
                    Text(i.name, style: theme.regularTextStyle),
                    Text(i.table, style: theme.regularTextStyle),
                    Text(i.columns.join(', '), style: mono),
                    Text(i.unique ? '✓' : '', style: theme.regularTextStyle),
                  ],
              ],
            ),
          ),
        if (overview.triggers.isNotEmpty)
          SchemaSection(
            title: 'Triggers',
            child: StaticTable(
              label: 'Triggers',
              headers: const ['Trigger', 'Table'],
              rows: [
                for (final t in overview.triggers)
                  [
                    Tooltip(
                        message: t.sql ?? '',
                        child: Text(t.name, style: theme.regularTextStyle)),
                    Text(t.table, style: theme.regularTextStyle),
                  ],
              ],
            ),
          ),
      ],
    );
  }
}

String _capitalize(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

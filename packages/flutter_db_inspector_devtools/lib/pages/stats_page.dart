import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import '../services/wording.dart';
import '../widgets/common.dart';
import '../widgets/schema_view.dart';
import '../widgets/toolbar.dart';

/// The Statistics tab: size, counts and the largest entities.
class StatsPage extends StatefulWidget {
  const StatsPage({
    super.key,
    required this.client,
    required this.database,
    required this.generation,
    this.onOpenEntity,
  });

  final InspectorClient client;
  final DatabaseDescriptor database;

  /// Reloads when this changes (reconnect, database list reload).
  final int generation;
  final void Function(String entity)? onOpenEntity;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  DatabaseStats? _stats;
  DatabaseInfo? _info;
  String? _error;
  bool _loading = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(StatsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.database.id != widget.database.id ||
        oldWidget.generation != widget.generation) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stats = await widget.client.stats(widget.database.id);
      DatabaseInfo? info;
      try {
        info = await widget.client.databaseInfo(widget.database.id);
      } on InspectorClientException {
        info = null; // Optional metadata.
      }
      if (!mounted || seq != _seq) return;
      setState(() {
        _stats = stats;
        _info = info;
      });
    } on InspectorClientException catch (e) {
      if (mounted && seq == _seq) setState(() => _error = Wording.error(e));
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = widget.database.dataModel;
    final stats = _stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InspectorToolbar(
          label: 'Statistics actions',
          children: [
            Text('Statistics', style: theme.boldTextStyle),
            const Spacer(),
            DevToolsButton.iconOnly(
              icon: Icons.refresh,
              tooltip: 'Refresh statistics',
              onPressed: _loading ? null : () => unawaited(_load()),
            ),
          ],
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _error != null
              ? Center(child: ErrorText(_error!))
              : stats == null
                  ? const SizedBox()
                  : ListView(
                      padding: const EdgeInsets.all(denseSpacing),
                      children: [
                        Wrap(
                          spacing: denseSpacing,
                          runSpacing: denseSpacing,
                          children: [
                            if (stats.sizeBytes != null)
                              _Tile('Size',
                                  WireValues.formatBytes(stats.sizeBytes!)),
                            _Tile(Wording.entities(model),
                                WireValues.formatCount(stats.entities.length)),
                            if (widget.database.capabilities
                                .contains(DbCapability.indexes))
                              _Tile('Indexes',
                                  WireValues.formatCount(stats.indexCount)),
                            if (stats.triggerCount > 0)
                              _Tile('Triggers',
                                  WireValues.formatCount(stats.triggerCount)),
                            _Tile(
                              _cap(Wording.record(model, plural: true)),
                              WireValues.formatCount(stats.totalRows),
                            ),
                          ],
                        ),
                        if (_info != null) ...[
                          const SizedBox(height: denseSpacing),
                          Text(
                            [
                              _info!.metadata.engine,
                              if (_info!.metadata.engineVersion != null)
                                _info!.metadata.engineVersion!,
                              if (_info!.metadata.path != null)
                                _info!.metadata.path!,
                            ].join(' · '),
                            style: theme.subtleTextStyle,
                          ),
                        ],
                        const SizedBox(height: defaultSpacing),
                        SchemaSection(
                          title:
                              'Largest ${Wording.entities(model).toLowerCase()}',
                          child: _largest(theme, stats),
                        ),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _largest(ThemeData theme, DatabaseStats stats) {
    final model = widget.database.dataModel;
    final sorted = [...stats.entities]
      ..sort((a, b) => (b.rowCount ?? 0).compareTo(a.rowCount ?? 0));
    final max =
        sorted.fold<int>(1, (m, e) => (e.rowCount ?? 0) > m ? e.rowCount! : m);
    return StaticTable(
      label: 'Largest ${Wording.entities(model).toLowerCase()}',
      headers: ['Name', _cap(Wording.record(model, plural: true)), 'Share'],
      flex: const [3, 1, 3],
      rows: [
        for (final e in sorted)
          [
            Row(
              children: [
                Flexible(
                  child: widget.onOpenEntity == null
                      ? Text(e.name, style: theme.regularTextStyle)
                      : InkWell(
                          onTap: () => widget.onOpenEntity!(e.name),
                          child: Text(e.name, style: theme.linkTextStyle),
                        ),
                ),
                if (e.kind == EntityKind.view) ...[
                  const SizedBox(width: densePadding),
                  const TagLabel('view'),
                ],
              ],
            ),
            Text(
              e.rowCount == null ? '—' : WireValues.formatCount(e.rowCount),
              style: theme.regularTextStyle,
              textAlign: TextAlign.right,
            ),
            Semantics(
              label:
                  '${((e.rowCount ?? 0) / max * 100).round()} percent of the largest',
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: ((e.rowCount ?? 0) / max).clamp(0.0, 1.0),
                  child: Container(
                      height: densePadding * 2,
                      color: theme.colorScheme.primary),
                ),
              ),
            ),
          ],
      ],
    );
  }
}

String _cap(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: 120),
        padding: const EdgeInsets.symmetric(
            horizontal: denseSpacing, vertical: densePadding),
        decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: theme.textTheme.titleMedium),
            Text(label, style: theme.subtleTextStyle),
          ],
        ),
      ),
    );
  }
}

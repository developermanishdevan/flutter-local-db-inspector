import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import '../services/wording.dart';
import 'common.dart';

/// Shows the add / duplicate record dialog. [onSubmit] may throw
/// [InspectorClientException]; the error is shown in the dialog.
Future<bool> showRowForm(
  BuildContext context, {
  required String title,
  required List<ColumnInfo> columns,
  required Future<void> Function(Map<String, WireValue> values) onSubmit,
  Map<String, WireValue> initial = const {},
  String submitLabel = 'Insert',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => RowForm(
      title: title,
      columns: columns,
      initial: initial,
      submitLabel: submitLabel,
      onSubmit: onSubmit,
    ),
  );
  return result ?? false;
}

/// Form to add (or duplicate) a record. Generated columns are skipped;
/// auto-assigned keys and columns with defaults may be left empty.
class RowForm extends StatefulWidget {
  const RowForm({
    super.key,
    required this.title,
    required this.columns,
    required this.onSubmit,
    this.initial = const {},
    this.submitLabel = 'Insert',
  });

  final String title;
  final List<ColumnInfo> columns;
  final Map<String, WireValue> initial;
  final String submitLabel;
  final Future<void> Function(Map<String, WireValue> values) onSubmit;

  @override
  State<RowForm> createState() => _RowFormState();
}

class _RowFormState extends State<RowForm> {
  late final List<ColumnInfo> _columns = [
    for (final c in widget.columns)
      if (!c.generated) c,
  ];
  late final Map<String, TextEditingController> _controllers = {
    for (final c in _columns)
      c.name: TextEditingController(
        text: switch (widget.initial[c.name]) {
          null => '',
          final v => WireValues.editText(v),
        },
      ),
  };
  late final Map<String, bool> _isNull = {
    for (final c in _columns)
      c.name: c.nullable &&
          !c.autoIncrement &&
          (widget.initial[c.name]?.isNull ?? false),
  };
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// The values to insert, parsed by column type.
  Map<String, WireValue> values() => {
        for (final c in _columns)
          if (_isNull[c.name]!)
            c.name: const WireNull()
          else if (!(_controllers[c.name]!.text.isEmpty &&
              (c.autoIncrement || c.defaultValue != null)))
            c.name:
                WireValues.parseInput(_controllers[c.name]!.text, c.valueType),
      };

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.onSubmit(values());
      if (mounted) Navigator.of(context).pop(true);
    } on InspectorClientException catch (e) {
      if (mounted) setState(() => _error = Wording.error(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DevToolsDialog(
      title: DialogTitleText(widget.title),
      content: SizedBox(
        width: 560,
        child: FocusTraversalGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final c in _columns) _field(theme, c),
              if (_error != null) ...[
                const SizedBox(height: denseSpacing),
                ErrorText(_error!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        DialogTextButton(
          onPressed:
              _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        DialogTextButton(
          onPressed: _submitting ? null : () => unawaited(_submit()),
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }

  Widget _field(ThemeData theme, ColumnInfo column) {
    final isNull = _isNull[column.name]!;
    final multiline = column.valueType == DbValueType.json ||
        column.valueType == DbValueType.unknown;
    final hint = column.autoIncrement
        ? 'auto'
        : column.defaultValue != null
            ? 'default: ${column.defaultValue}'
            : null;
    final details = [
      if (column.declaredType.isNotEmpty)
        column.declaredType
      else
        column.valueType.wireName,
      if (!column.nullable) 'required',
      if (column.isPrimaryKey) 'key',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: densePadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Padding(
              padding: const EdgeInsets.only(top: densePadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(column.name,
                      style: theme.boldTextStyle,
                      overflow: TextOverflow.ellipsis),
                  Text(details,
                      style: theme.subtleTextStyle
                          .copyWith(fontSize: smallFontSize)),
                ],
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _controllers[column.name],
              enabled: !isNull && !_submitting,
              minLines: 1,
              maxLines: multiline ? 6 : 1,
              style: multiline ? monoStyle(theme) : theme.regularTextStyle,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: hint,
                labelText: column.name,
              ),
              onSubmitted: multiline ? null : (_) => unawaited(_submit()),
            ),
          ),
          const SizedBox(width: densePadding),
          Tooltip(
            message: column.nullable ? 'Store NULL' : 'Not nullable',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: isNull,
                  semanticLabel: '${column.name} is NULL',
                  onChanged: column.nullable && !_submitting
                      ? (v) => setState(() => _isNull[column.name] = v ?? false)
                      : null,
                ),
                Text('NULL', style: theme.subtleTextStyle),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

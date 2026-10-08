import 'dart:async';
import 'dart:convert';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import '../services/wording.dart';
import 'common.dart';

/// Side panel showing one value in full: JSON pretty/raw, long text (loaded
/// with `value.read`), blob hex preview, and an editor.
class ValueInspector extends StatefulWidget {
  const ValueInspector({
    super.key,
    required this.column,
    required this.valueType,
    required this.value,
    required this.onCopy,
    required this.onClose,
    this.editable = false,
    this.nullable = true,
    this.loadFull,
    this.onSave,
  });

  final String column;
  final DbValueType valueType;
  final WireValue value;
  final bool editable;
  final bool nullable;

  /// Reads the complete value (truncated text, blobs) up to `maxBytes`.
  final Future<FullValue> Function(int maxBytes)? loadFull;
  final void Function(String text) onCopy;

  /// Saves a new value; resolves to `true` on success.
  final Future<bool> Function(WireValue value)? onSave;
  final VoidCallback onClose;

  static const fullTextLimit = 10 * 1024 * 1024;
  static const blobPreviewBytes = 64 * 1024;

  @override
  State<ValueInspector> createState() => _ValueInspectorState();
}

class _ValueInspectorState extends State<ValueInspector> {
  final _editor = TextEditingController();
  String? _fullText;
  bool _fullComplete = true;
  Uint8List? _blobBytes;
  bool _pretty = true;
  bool _loading = false;
  bool _saving = false;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(ValueInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.column != widget.column || oldWidget.value != widget.value) {
      _reset();
    }
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  void _reset() {
    _fullText = null;
    _fullComplete = true;
    _blobBytes = null;
    _loading = false;
    _error = null;
    _status = null;
    _editor.text = _editableText();
  }

  /// The text shown (null for blobs and masked values).
  String? get _text {
    if (_fullText != null) return _fullText;
    return switch (widget.value) {
      WireTruncatedText(:final preview) => preview,
      WireBlob() || WireMasked() => null,
      final v => WireValues.editText(v),
    };
  }

  Object? get _json {
    final text = _text?.trim();
    if (text == null ||
        text.isEmpty ||
        !(text.startsWith('{') || text.startsWith('['))) {
      return null;
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  String _shownText() {
    final json = _json;
    if (json != null && _pretty) {
      return const JsonEncoder.withIndent('  ').convert(json);
    }
    return _text ?? '';
  }

  String _editableText() {
    final json = _json;
    if (json != null) return const JsonEncoder.withIndent('  ').convert(json);
    return _text ?? '';
  }

  Future<void> _loadFullText() async {
    final load = widget.loadFull;
    if (load == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final full = await load(ValueInspector.fullTextLimit);
      if (!mounted) return;
      setState(() {
        _fullText = full.text ?? '';
        _fullComplete = full.complete;
        _editor.text = _editableText();
      });
    } on InspectorClientException catch (e) {
      if (mounted) setState(() => _error = Wording.error(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadBlobPreview() async {
    final load = widget.loadFull;
    if (load == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final full = await load(ValueInspector.blobPreviewBytes);
      if (mounted) setState(() => _blobBytes = full.bytes);
    } on InspectorClientException catch (e) {
      if (mounted) setState(() => _error = Wording.error(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(String? text) async {
    final save = widget.onSave;
    if (save == null || _saving) return;
    setState(() {
      _saving = true;
      _status = 'Saving…';
    });
    final value = text == null
        ? const WireNull()
        : WireValues.parseInput(text, widget.valueType);
    final ok = await save(value);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _status = ok ? 'Saved' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: 'Value inspector for ${widget.column}',
      container: true,
      child: Container(
        decoration: BoxDecoration(
          border:
              Border(left: BorderSide(color: theme.colorScheme.outlineVariant)),
          color: theme.colorScheme.surface,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AreaPaneHeader(
              roundedTopBorder: false,
              includeTopBorder: false,
              title: Row(
                children: [
                  Flexible(
                    child: Text(widget.column,
                        style: theme.boldTextStyle,
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: densePadding),
                  TagLabel(widget.valueType.wireName),
                ],
              ),
              actions: [
                DevToolsButton.iconOnly(
                  icon: Icons.close,
                  tooltip: 'Close (Esc)',
                  outlined: false,
                  onPressed: widget.onClose,
                ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(denseSpacing),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _content(theme),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(ThemeData theme) {
    final value = widget.value;
    if (value is WireMasked) {
      return [
        _notice(
          theme,
          Icons.lock_outline,
          'This column is marked sensitive by the app. Its value never leaves the device.',
        ),
      ];
    }
    if (value is WireBlob) return _blob(theme, value);

    final json = _json;
    final partial = value.isPartial && _fullText == null;
    return [
      Wrap(
        spacing: densePadding,
        runSpacing: densePadding,
        children: [
          if (json != null)
            DevToolsToggleButtonGroup(
              selectedStates: [_pretty, !_pretty],
              onPressed: (i) => setState(() => _pretty = i == 0),
              children: const [
                Padding(
                    padding: EdgeInsets.symmetric(horizontal: denseSpacing),
                    child: Text('Pretty')),
                Padding(
                    padding: EdgeInsets.symmetric(horizontal: denseSpacing),
                    child: Text('Raw')),
              ],
            ),
          DevToolsButton(
            icon: Icons.copy,
            label: 'Copy',
            onPressed: () => widget.onCopy(_shownText()),
          ),
        ],
      ),
      const SizedBox(height: denseSpacing),
      if (partial && value is WireTruncatedText)
        _notice(
          theme,
          Icons.info_outline,
          'Showing a preview of ${WireValues.formatBytes(value.size)}.',
          action: widget.loadFull == null
              ? null
              : DevToolsButton(
                  icon: Icons.download,
                  label: 'Load full value',
                  onPressed: _loading ? null : () => unawaited(_loadFullText()),
                ),
        ),
      if (!_fullComplete)
        _notice(
          theme,
          Icons.warning_amber,
          'Only the first ${WireValues.formatBytes(ValueInspector.fullTextLimit)} were loaded.',
        ),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) ErrorText(_error!),
      if (value.isNull)
        Text('NULL', style: cellStyle(theme, CellKind.nullValue))
      else
        SelectableText(_shownText(), style: monoStyle(theme)),
      if (widget.editable && widget.onSave != null && !partial)
        ..._editorSection(theme),
    ];
  }

  List<Widget> _blob(ThemeData theme, WireBlob value) {
    final bytes = _blobBytes ?? value.previewBytes;
    return [
      Row(
        children: [
          const Icon(Icons.memory, size: defaultIconSize),
          const SizedBox(width: densePadding),
          Text('Binary value, ${WireValues.formatBytes(value.size)}'),
        ],
      ),
      const SizedBox(height: denseSpacing),
      if (widget.loadFull != null && _blobBytes == null)
        Align(
          alignment: Alignment.centerLeft,
          child: DevToolsButton(
            icon: Icons.visibility_outlined,
            label:
                'Load preview (${WireValues.formatBytes(value.size < ValueInspector.blobPreviewBytes ? value.size : ValueInspector.blobPreviewBytes)})',
            onPressed: _loading ? null : () => unawaited(_loadBlobPreview()),
          ),
        ),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) ErrorText(_error!),
      const SizedBox(height: denseSpacing),
      SelectableText(
        WireValues.hexDump(bytes),
        style: monoStyle(theme),
        semanticsLabel: 'Hex preview of ${bytes.length} bytes',
      ),
    ];
  }

  List<Widget> _editorSection(ThemeData theme) => [
        const SizedBox(height: defaultSpacing),
        const PaddedDivider.thin(),
        Text('Edit value', style: theme.boldTextStyle),
        const SizedBox(height: densePadding),
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                () => unawaited(_save(_editor.text)),
            const SingleActivator(LogicalKeyboardKey.enter, meta: true): () =>
                unawaited(_save(_editor.text)),
          },
          child: TextField(
            controller: _editor,
            minLines: 3,
            maxLines: 12,
            style: monoStyle(theme),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: 'New value of ${widget.column}',
            ),
          ),
        ),
        const SizedBox(height: densePadding),
        Wrap(
          spacing: densePadding,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DevToolsButton(
              icon: Icons.save_outlined,
              label: 'Save',
              tooltip: 'Save (Ctrl/Cmd+Enter)',
              elevated: true,
              onPressed: _saving ? null : () => unawaited(_save(_editor.text)),
            ),
            if (widget.nullable)
              DevToolsButton(
                icon: Icons.block,
                label: 'Set NULL',
                onPressed: _saving ? null : () => unawaited(_save(null)),
              ),
            if (_status != null)
              Semantics(
                  liveRegion: true,
                  child: Text(_status!, style: theme.subtleTextStyle)),
          ],
        ),
      ];

  Widget _notice(ThemeData theme, IconData icon, String text,
      {Widget? action}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: denseSpacing),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: densePadding,
        runSpacing: densePadding,
        children: [
          Icon(icon,
              size: defaultIconSize, color: theme.colorScheme.subtleTextColor),
          Text(text, style: theme.subtleTextStyle),
          if (action != null) action,
        ],
      ),
    );
  }
}

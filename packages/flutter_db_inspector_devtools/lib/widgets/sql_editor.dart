import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart';

/// The statement to run: the selection when there is one, else everything.
String selectedSql(TextEditingController controller) {
  final selection = controller.selection;
  final text = controller.text;
  if (selection.isValid && !selection.isCollapsed) {
    return selection.textInside(text).trim();
  }
  return text.trim();
}

/// Monospace SQL editor. Ctrl/Cmd+Enter runs the query (or the selection);
/// Tab inserts two spaces.
class SqlEditor extends StatelessWidget {
  const SqlEditor({
    super.key,
    required this.controller,
    required this.onRun,
    this.focusNode,
    this.onChanged,
    this.hintText,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback onRun;
  final ValueChanged<String>? onChanged;
  final String? hintText;

  void _insertIndent() {
    final value = controller.value;
    final selection = value.selection;
    if (!selection.isValid) return;
    final text = value.text.replaceRange(selection.start, selection.end, '  ');
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: selection.start + 2),
    );
    onChanged?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): onRun,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): onRun,
        const SingleActivator(LogicalKeyboardKey.tab): _insertIndent,
      },
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        expands: true,
        maxLines: null,
        minLines: null,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        style: monoStyle(theme),
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(denseSpacing),
          hintText: hintText ??
              'SELECT * FROM … LIMIT 50;\n\nCtrl/Cmd+Enter runs the query (or the selection).',
          hintStyle: monoStyle(theme)
              .copyWith(color: theme.colorScheme.subtleTextColor),
          semanticCounterText: '',
        ),
      ),
    );
  }
}

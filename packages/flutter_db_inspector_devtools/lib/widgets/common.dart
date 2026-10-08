import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

/// Monospace text (RobotoMono ships with `devtools_app_shared`).
TextStyle monoStyle(ThemeData theme) => theme.regularTextStyle.copyWith(
      fontFamily: 'RobotoMono',
      package: 'devtools_app_shared',
      fontSize: defaultFontSize - 0.5,
    );

/// Style of a grid cell by value kind. Colors come from the DevTools theme.
TextStyle cellStyle(ThemeData theme, CellKind kind) {
  final base = theme.regularTextStyle;
  final scheme = theme.colorScheme;
  return switch (kind) {
    CellKind.nullValue => base.copyWith(
        color: scheme.subtleTextColor,
        fontStyle: FontStyle.italic,
      ),
    CellKind.number => monoStyle(theme).copyWith(color: scheme.tertiary),
    CellKind.boolean => monoStyle(theme).copyWith(color: scheme.secondary),
    CellKind.date => monoStyle(theme),
    CellKind.json => monoStyle(theme),
    CellKind.masked => base.copyWith(color: scheme.subtleTextColor),
    CellKind.partial || CellKind.blob || CellKind.unknown => base.copyWith(
        color: scheme.subtleTextColor,
        fontStyle: FontStyle.italic,
      ),
    CellKind.text => base,
  };
}

/// Whether the platform's primary modifier (Cmd on macOS, Ctrl elsewhere)
/// is pressed.
bool isPrimaryModifierPressed() {
  final keys = HardwareKeyboard.instance;
  return keys.isMetaPressed || keys.isControlPressed;
}

/// A small rounded label ("read-only", "view", "integer").
class TagLabel extends StatelessWidget {
  const TagLabel(this.text, {super.key, this.tooltip, this.warning = false});

  final String text;
  final String? tooltip;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = Container(
      padding: const EdgeInsets.symmetric(horizontal: densePadding),
      decoration: BoxDecoration(
        color: warning ? scheme.warningContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(densePadding),
      ),
      child: Text(
        text,
        style: theme.regularTextStyle.copyWith(
          fontSize: smallFontSize,
          color: warning ? scheme.onWarningContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
    return tooltip == null ? label : Tooltip(message: tooltip, child: label);
  }
}

/// A centered, subtle message for empty states.
class EmptyMessage extends StatelessWidget {
  const EmptyMessage(this.message, {super.key, this.icon, this.action});

  final String message;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(defaultSpacing),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(icon,
                  size: actionsIconSize * 2,
                  color: theme.colorScheme.subtleTextColor),
            const SizedBox(height: denseSpacing),
            Text(message,
                style: theme.subtleTextStyle, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: denseSpacing),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// One-line error text with an icon.
class ErrorText extends StatelessWidget {
  const ErrorText(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline,
              size: defaultIconSize, color: theme.colorScheme.error),
          const SizedBox(width: densePadding),
          Flexible(
            child: Text(
              message,
              style: theme.errorTextStyle,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks a yes/no question. Resolves to `true` only for [confirmLabel].
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return DevToolsDialog(
        title: DialogTitleText(title),
        content: SizedBox(width: 420, child: Text(message)),
        actions: [
          DialogTextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          DialogTextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              confirmLabel,
              style: destructive
                  ? TextStyle(color: theme.colorScheme.error)
                  : null,
            ),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

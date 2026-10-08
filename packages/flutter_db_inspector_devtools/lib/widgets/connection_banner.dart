import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

/// Color of the connection dot, from the DevTools theme.
Color connectionColor(ColorScheme scheme, InspectorConnectionState state) =>
    switch (state) {
      InspectorConnectionState.connected => scheme.primary,
      InspectorConnectionState.connecting ||
      InspectorConnectionState.reconnecting =>
        scheme.tertiary,
      InspectorConnectionState.error => scheme.error,
      InspectorConnectionState.disconnected => scheme.subtleTextColor,
    };

String connectionLabel(InspectorConnectionState state) => switch (state) {
      InspectorConnectionState.connected => 'Connected',
      InspectorConnectionState.connecting => 'Connecting…',
      InspectorConnectionState.reconnecting => 'Reconnecting…',
      InspectorConnectionState.error => 'Error',
      InspectorConnectionState.disconnected => 'Disconnected',
    };

/// One-line status: `● Connected` / `● Reconnecting…`.
class ConnectionStatusLine extends StatelessWidget {
  const ConnectionStatusLine({super.key, required this.snapshot});

  final ConnectionSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = snapshot.status;
    final detail = snapshot.isConnected && status != null
        ? 'flutter_db_inspector ${status.packageVersion} · protocol v${status.protocolVersion} · ${status.mode.name}'
        : snapshot.message ?? connectionLabel(snapshot.state);
    return Semantics(
      liveRegion: true,
      label: 'Connection: ${connectionLabel(snapshot.state)}',
      child: Tooltip(
        message: detail,
        child: Container(
          height: statusLineHeight + densePadding,
          padding: const EdgeInsets.symmetric(horizontal: denseSpacing),
          decoration: BoxDecoration(
            border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          child: Row(
            children: [
              Text('●',
                  style: TextStyle(
                      color: connectionColor(theme.colorScheme, snapshot.state),
                      fontSize: smallFontSize)),
              const SizedBox(width: densePadding),
              Text(connectionLabel(snapshot.state),
                  style: theme.regularTextStyle),
              if (snapshot.isConnected && status != null) ...[
                const SizedBox(width: densePadding),
                Flexible(
                  child: Text(
                    status.mode == InspectorMode.readOnly
                        ? 'read-only mode'
                        : 'v${status.packageVersion}',
                    style: theme.subtleTextStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Banner above the main area while not connected, with a retry action.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.snapshot, this.onRetry});

  final ConnectionSnapshot snapshot;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (snapshot.isConnected) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final error = snapshot.state == InspectorConnectionState.error;
    final busy = snapshot.state == InspectorConnectionState.connecting ||
        snapshot.state == InspectorConnectionState.reconnecting;
    final background = error ? scheme.errorContainer : scheme.warningContainer;
    final foreground =
        error ? scheme.onErrorContainer : scheme.onWarningContainer;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        color: background,
        padding: const EdgeInsets.symmetric(
            horizontal: denseSpacing, vertical: densePadding),
        child: Row(
          children: [
            if (busy)
              SizedBox(
                width: smallProgressSize,
                height: smallProgressSize,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: foreground),
              )
            else
              Icon(error ? Icons.error_outline : Icons.link_off,
                  size: defaultIconSize, color: foreground),
            const SizedBox(width: denseSpacing),
            Expanded(
              child: Text(
                snapshot.message ?? connectionLabel(snapshot.state),
                style: theme.regularTextStyle.copyWith(color: foreground),
              ),
            ),
            if (onRetry != null &&
                (error ||
                    snapshot.state == InspectorConnectionState.connecting))
              TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

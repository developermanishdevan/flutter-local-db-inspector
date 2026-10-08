import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

import '../services/host.dart';
import '../services/inspector_controller.dart';
import '../widgets/connection_banner.dart';
import '../widgets/database_tree.dart';
import 'database_page.dart';

/// The extension's root screen: sidebar (databases tree + connection status)
/// and the main area.
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.host,
    this.onRetryConnection,
  });

  final InspectorController controller;
  final InspectorHost host;
  final VoidCallback? onRetryConnection;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.connection;
        return Material(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConnectionBanner(snapshot: snapshot, onRetry: onRetryConnection),
              Expanded(
                child: SplitPane(
                  axis: Axis.horizontal,
                  initialFractions: const [0.24, 0.76],
                  minSizes: const [180, 360],
                  children: [
                    _sidebar(context, snapshot),
                    FocusTraversalGroup(
                        child:
                            DatabasePage(controller: controller, host: host)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sidebar(BuildContext context, ConnectionSnapshot snapshot) {
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AreaPaneHeader(
            roundedTopBorder: false,
            includeTopBorder: false,
            title: const Text('DATABASES'),
            actions: [
              DevToolsButton.iconOnly(
                icon: Icons.refresh,
                tooltip: 'Reload databases',
                outlined: false,
                onPressed: controller.isConnected
                    ? () => unawaited(controller.refreshAll())
                    : null,
              ),
            ],
          ),
          if (controller.loadingDatabases)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(child: DatabaseTree(controller: controller)),
          ConnectionStatusLine(snapshot: snapshot),
        ],
      ),
    );
  }
}

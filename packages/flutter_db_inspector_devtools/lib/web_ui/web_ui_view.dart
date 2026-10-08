import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/connection_manager.dart';
import 'bridge.dart';
import 'platform_stub.dart' if (dart.library.js_interop) 'platform_web.dart'
    as platform;

export 'bridge.dart';

/// Which UI the extension shows.
enum InspectorUi {
  /// The shared web UI (`shared/web-ui`) in an iframe. The default.
  web,

  /// The original Flutter UI (pages/ and widgets/), kept as a fallback.
  classic;

  /// `?ui=classic` in the URL, else the last choice; [web] by default.
  static InspectorUi load() =>
      platform.readUiMode() == classic.name ? classic : web;

  void save() => platform.writeUiMode(name);
}

/// Saves a file through a browser download (no-op outside the browser).
void downloadFile(String name, Uint8List bytes) =>
    platform.downloadFile(name, bytes);

/// The shared web UI, connected to [connection].
class WebUiView extends StatelessWidget {
  const WebUiView({
    super.key,
    required this.connection,
    required this.darkTheme,
    required this.services,
    required this.onUseClassic,
  });

  final ConnectionManager connection;
  final ValueListenable<bool> darkTheme;
  final WebUiServices services;

  /// Switches to the classic UI (offered when the web UI is missing).
  final VoidCallback onUseClassic;

  @override
  Widget build(BuildContext context) => platform.buildWebUiFrame(
        createBridge: (post) => WebUiBridge(
          post: post,
          sender: connection.connection,
          connection: connection.snapshot,
          databasesChanged: connection.databasesChanged,
          darkTheme: darkTheme,
          services: services,
        ),
        missing: _Missing(onUseClassic: onUseClassic),
        dark: darkTheme.value,
      );
}

class _Missing extends StatelessWidget {
  const _Missing({required this.onUseClassic});

  final VoidCallback onUseClassic;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The web UI is not part of this build. Run '
                'tool/sync_web_ui.sh in flutter_db_inspector_devtools before '
                'building the extension.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onUseClassic,
                child: const Text('Use the classic UI'),
              ),
            ],
          ),
        ),
      );
}

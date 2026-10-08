import 'dart:typed_data';

import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'services/connection_manager.dart';
import 'services/host.dart';
import 'services/inspector_controller.dart';
import 'web_ui/web_ui_view.dart';

/// Flutter DB Inspector DevTools extension.
///
/// Development: `flutter run -d chrome --dart-define=use_simulated_environment=true`
/// (see docs/devtools.md).
void main() =>
    runApp(const DevToolsExtension(child: FlutterDbInspectorExtension()));

/// Wires DevTools' VM service connection into the inspector: the shared web
/// UI by default, the classic Flutter UI on request.
class FlutterDbInspectorExtension extends StatefulWidget {
  const FlutterDbInspectorExtension({super.key});

  @override
  State<FlutterDbInspectorExtension> createState() =>
      _FlutterDbInspectorExtensionState();
}

class _FlutterDbInspectorExtensionState
    extends State<FlutterDbInspectorExtension> {
  late final ConnectionManager _connection;
  InspectorController? _controller;
  InspectorUi _ui = InspectorUi.load();
  final _host = _DevToolsHost();

  @override
  void initState() {
    super.initState();
    _connection =
        ConnectionManager(source: ServiceManagerSource(serviceManager))
          ..start();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _connection.dispose();
    super.dispose();
  }

  void _use(InspectorUi ui) {
    if (ui == _ui) return;
    ui.save();
    setState(() {
      _ui = ui;
      // The classic UI's state only lives while it is shown.
      // Disposed after the pages that listen to it are gone.
      final old = ui == InspectorUi.web ? _controller : null;
      if (old != null) {
        _controller = null;
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    });
  }

  InspectorController get _classic => _controller ??= InspectorController(
        client: _connection.client,
        connection: _connection.snapshot,
        databasesChanged: _connection.databasesChanged,
      );

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: switch (_ui) {
              InspectorUi.web => WebUiView(
                  connection: _connection,
                  darkTheme: extensionManager.darkThemeEnabled,
                  services: _host,
                  onUseClassic: () => _use(InspectorUi.classic),
                ),
              InspectorUi.classic => HomePage(
                  controller: _classic,
                  host: _host,
                  onRetryConnection: _connection.retry,
                ),
            },
          ),
          _UiSwitch(ui: _ui, onChanged: _use),
        ],
      );
}

/// A slim footer to switch between the web UI and the classic UI.
class _UiSwitch extends StatelessWidget {
  const _UiSwitch({required this.ui, required this.onChanged});

  final InspectorUi ui;
  final ValueChanged<InspectorUi> onChanged;

  @override
  Widget build(BuildContext context) {
    final classic = ui == InspectorUi.classic;
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        height: 24,
        child: TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            textStyle: Theme.of(context).textTheme.labelSmall,
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () =>
              onChanged(classic ? InspectorUi.web : InspectorUi.classic),
          child: Text(classic ? 'Switch to the new UI' : 'Classic UI'),
        ),
      ),
    );
  }
}

/// Clipboard, notifications and downloads through DevTools (works inside
/// IDE web views, where the iframe cannot use the clipboard directly).
class _DevToolsHost implements InspectorHost, WebUiServices {
  @override
  void copyToClipboard(String text, {String what = 'value'}) => extensionManager
      .copyToClipboard(text, successMessage: 'Copied $what to the clipboard');

  @override
  void notify(String message, {String? level}) =>
      extensionManager.showNotification(message);

  @override
  void copy(String text, {String? label}) =>
      copyToClipboard(text, what: label ?? 'value');

  @override
  void saveFile(String name, Uint8List bytes) => downloadFile(name, bytes);

  @override
  void log(String message) => debugPrint(message);
}

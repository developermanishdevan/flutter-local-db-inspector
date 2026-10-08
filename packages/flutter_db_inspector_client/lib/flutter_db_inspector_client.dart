/// Pure Dart client for Flutter DB Inspector.
///
/// ```dart
/// final connection = await InspectorConnection.connectUri(vmServiceUri);
/// final client = InspectorClient(connection);
/// final databases = await client.listDatabases();
/// ```
///
/// [InspectorConnection] finds the app's inspector isolate through the Dart
/// VM service and keeps the connection alive across hot restarts;
/// [InspectorClient] exposes the protocol (`docs/protocol.md`) as typed
/// calls returning `flutter_db_inspector_protocol` models; [WireValue] and
/// [WireValues] implement display and input rules shared by every UI.
library;

export 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

export 'src/client.dart';
export 'src/connection.dart';
export 'src/exception.dart';
export 'src/results.dart';
export 'src/uri.dart';
export 'src/values.dart';

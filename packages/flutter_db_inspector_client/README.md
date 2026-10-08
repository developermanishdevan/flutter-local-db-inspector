# flutter_db_inspector_client

Pure Dart client for Flutter DB Inspector. It connects to a running app
through the Dart VM service, survives hot restarts and exposes the inspector
protocol as typed calls.

Used by the DevTools extension. It is not published on pub.dev.

```dart
final connection = await InspectorConnection.connectUri(vmServiceUri);
final client = InspectorClient(connection);

final databases = await client.listDatabases();
final page = await client.queryRows(databases.first.id, 'users');
```

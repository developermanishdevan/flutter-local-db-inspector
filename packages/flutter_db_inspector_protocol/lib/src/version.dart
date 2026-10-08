/// Protocol version spoken by this package.
///
/// The protocol version is a single integer major version. Additive changes
/// (new methods, new optional fields) do not bump it; clients discover them
/// through the `methods` list returned by `inspector.status`.
const int protocolVersion = 1;

/// Every protocol major version this package can still answer.
const List<int> supportedProtocolVersions = [1];

/// The single VM service extension through which every request flows.
const String serviceExtensionName = 'ext.flutter_db_inspector.request';

/// Name of the service extension parameter carrying the JSON request.
const String serviceExtensionRequestParam = 'request';

/// Events posted on the VM service `Extension` stream.
abstract final class InspectorEvents {
  /// Databases were registered or unregistered; clients should re-run
  /// `database.list`. Payload: `{"databases": [<id>, ...]}`.
  static const databasesChanged = 'flutter_db_inspector.databasesChanged';
}

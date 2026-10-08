import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

/// Error codes produced by the client itself (never sent by the runtime).
abstract final class ClientErrorCodes {
  /// No app is connected (or it never came back after a restart).
  static const notConnected = 'NOT_CONNECTED';

  /// The connection or the isolate went away while a request was running.
  static const connectionLost = 'CONNECTION_LOST';

  /// The app did not answer within the client's request timeout.
  static const clientTimeout = 'CLIENT_TIMEOUT';

  /// The app answered with something that is not a protocol response.
  static const malformedResponse = 'MALFORMED_RESPONSE';
}

/// A protocol error returned by the app, or a connection problem detected by
/// the client ([ClientErrorCodes]).
final class InspectorClientException implements Exception {
  const InspectorClientException(
    this.code,
    this.message, [
    this.details = const {},
  ]);

  factory InspectorClientException.fromError(InspectorError error) =>
      InspectorClientException(error.code, error.message, error.details);

  final String code;
  final String message;
  final JsonMap details;

  /// True when a write was refused only because it was not yet confirmed;
  /// resend with `allowWrite: true` after asking the user.
  bool get requiresConfirmation =>
      code == ErrorCodes.writeNotAllowed &&
      details['requiresConfirmation'] == true;

  /// True for errors caused by the connection rather than by the request.
  bool get isConnectionProblem =>
      code == ClientErrorCodes.notConnected ||
      code == ClientErrorCodes.connectionLost ||
      code == ClientErrorCodes.clientTimeout;

  @override
  String toString() => 'InspectorClientException($code): $message';
}

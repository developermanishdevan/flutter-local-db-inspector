import 'json.dart';

/// Standard error codes. Clients must tolerate codes they do not know.
abstract final class ErrorCodes {
  static const invalidRequest = 'INVALID_REQUEST';
  static const unsupportedProtocolVersion = 'UNSUPPORTED_PROTOCOL_VERSION';
  static const inspectorDisabled = 'INSPECTOR_DISABLED';
  static const databaseNotFound = 'DATABASE_NOT_FOUND';
  static const tableNotFound = 'TABLE_NOT_FOUND';
  static const columnNotFound = 'COLUMN_NOT_FOUND';
  static const rowNotFound = 'ROW_NOT_FOUND';
  static const queryFailed = 'QUERY_FAILED';
  static const permissionDenied = 'PERMISSION_DENIED';
  static const writeNotAllowed = 'WRITE_NOT_ALLOWED';
  static const unsupportedOperation = 'UNSUPPORTED_OPERATION';
  static const adapterNotSupported = 'ADAPTER_NOT_SUPPORTED';
  static const transactionFailed = 'TRANSACTION_FAILED';
  static const queryTimeout = 'QUERY_TIMEOUT';
  static const resultTooLarge = 'RESULT_TOO_LARGE';
  static const databaseBusy = 'DATABASE_BUSY';
  static const internalError = 'INTERNAL_ERROR';
}

/// A structured protocol error. Raw exceptions are never sent over the wire.
final class InspectorError {
  const InspectorError(this.code, this.message, [this.details = const {}]);

  factory InspectorError.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return InspectorError(
      r.optString('code') ?? ErrorCodes.internalError,
      r.optString('message') ?? 'Unknown error',
      r.optMap('details') ?? const {},
    );
  }

  final String code;
  final String message;
  final JsonMap details;

  JsonMap toJson() => {'code': code, 'message': message, 'details': details};

  @override
  String toString() => '$code: $message';
}

/// Thrown inside the runtime and adapters; converted to an error response by
/// the router.
final class InspectorException implements Exception {
  InspectorException(String code, String message, [JsonMap details = const {}])
      : error = InspectorError(code, message, details);

  final InspectorError error;

  String get code => error.code;

  @override
  String toString() => 'InspectorException(${error.code}): ${error.message}';
}

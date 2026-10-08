import 'errors.dart';
import 'json.dart';
import 'version.dart';

/// A protocol request.
///
/// ```json
/// {"version": 1, "requestId": "abc", "method": "database.list", "params": {}}
/// ```
final class InspectorRequest {
  const InspectorRequest({
    required this.method,
    this.requestId = '',
    this.params = const {},
    this.version = protocolVersion,
  });

  /// Parses and validates a request. Throws [InspectorException] with
  /// [ErrorCodes.invalidRequest] for malformed input.
  factory InspectorRequest.fromJson(Object? json) {
    final r = JsonReader.of(json, 'request');
    return InspectorRequest(
      version: r.optInt('version') ?? protocolVersion,
      requestId: r.optString('requestId') ?? '',
      method: r.string('method'),
      params: r.optMap('params') ?? const {},
    );
  }

  final int version;
  final String requestId;
  final String method;
  final JsonMap params;

  JsonReader get reader => JsonReader(params);

  JsonMap toJson() => {
        'version': version,
        'requestId': requestId,
        'method': method,
        'params': params,
      };
}

/// A protocol response: either [InspectorSuccess] or [InspectorFailure].
sealed class InspectorResponse {
  const InspectorResponse(
      {required this.requestId, this.version = protocolVersion});

  factory InspectorResponse.fromJson(Object? json) {
    final r = JsonReader.of(json, 'response');
    final version = r.optInt('version') ?? protocolVersion;
    final requestId = r.optString('requestId') ?? '';
    if (r.boolean('success')) {
      return InspectorSuccess(
        requestId: requestId,
        version: version,
        result: r.optMap('result') ?? const {},
      );
    }
    return InspectorFailure(
      requestId: requestId,
      version: version,
      error: InspectorError.fromJson(r.optMap('error') ?? const {}),
    );
  }

  final int version;
  final String requestId;

  bool get success;

  JsonMap toJson();
}

final class InspectorSuccess extends InspectorResponse {
  const InspectorSuccess({
    required super.requestId,
    required this.result,
    super.version,
  });

  final JsonMap result;

  @override
  bool get success => true;

  @override
  JsonMap toJson() => {
        'version': version,
        'requestId': requestId,
        'success': true,
        'result': result,
      };
}

final class InspectorFailure extends InspectorResponse {
  const InspectorFailure({
    required super.requestId,
    required this.error,
    super.version,
  });

  final InspectorError error;

  @override
  bool get success => false;

  @override
  JsonMap toJson() => {
        'version': version,
        'requestId': requestId,
        'success': false,
        'error': error.toJson(),
      };
}

# flutter_db_inspector_protocol

Wire protocol for [Flutter DB Inspector](https://pub.dev/packages/flutter_db_inspector):
the requests, responses, models and value encoding shared by the runtime and
all of its clients (DevTools, VS Code, Android Studio).

Apps don't need to depend on this package directly; it comes in through
`flutter_db_inspector`.

It contains:

- Method names and the request/response envelope
- Models for databases, schema, rows, SQL results and limits
- `WireValue` encoding for every cell type, including large values
- Error codes and `InspectorException`
- Capabilities and the protocol version

See [docs/protocol.md](https://github.com/developermanishdevan/flutter-local-db-inspector/blob/main/docs/protocol.md).

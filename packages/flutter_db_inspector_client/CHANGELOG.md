## 2.0.0

- Uses the protocol from `package:flutter_db_inspector/protocol.dart`;
  `flutter_db_inspector_protocol` was merged into `flutter_db_inspector`.
- `ConnectionSnapshot.appPackage`: the running app's Dart package name,
  read from the isolate's root library after the handshake (`appPackageOf`).

## 1.0.0

- Initial release.
- Pure Dart client that connects to a running app through the Dart VM service.
- Survives hot restarts and exposes the inspector protocol as typed calls.

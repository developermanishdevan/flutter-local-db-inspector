## 2.0.0

- Uses the protocol from `package:flutter_db_inspector/protocol.dart`;
  `flutter_db_inspector_protocol` was merged into `flutter_db_inspector`.
- SQL saved queries are kept per app (its Dart package name) until you
  delete them: in the project's `.dart_tool/` through the Dart Tooling
  Daemon, or in the browser's storage when DTD is not available.

## 1.0.0

- Initial release.
- DevTools extension (Flutter web app), built into `flutter_db_inspector/extension/devtools`.

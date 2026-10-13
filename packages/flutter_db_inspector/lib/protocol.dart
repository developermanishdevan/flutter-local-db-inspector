/// Wire protocol shared by the Flutter DB Inspector runtime and its clients
/// (DevTools, VS Code, Android Studio).
///
/// Everything in this library is pure Dart and free of any database or UI
/// dependency.
library;

export 'src/protocol/capability.dart';
export 'src/protocol/envelope.dart';
export 'src/protocol/errors.dart';
export 'src/protocol/json.dart' show JsonMap;
export 'src/protocol/methods.dart';
export 'src/protocol/models/database.dart';
export 'src/protocol/models/limits.dart';
export 'src/protocol/models/rows.dart';
export 'src/protocol/models/schema.dart';
export 'src/protocol/models/sql.dart';
export 'src/protocol/value.dart';
export 'src/protocol/version.dart';

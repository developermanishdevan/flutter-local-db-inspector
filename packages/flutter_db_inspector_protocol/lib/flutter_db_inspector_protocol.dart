/// Wire protocol shared by the Flutter DB Inspector runtime and its clients
/// (DevTools, VS Code, Android Studio).
///
/// Everything in this library is pure Dart and free of any database or UI
/// dependency.
library;

export 'src/capability.dart';
export 'src/envelope.dart';
export 'src/errors.dart';
export 'src/json.dart' show JsonMap;
export 'src/methods.dart';
export 'src/models/database.dart';
export 'src/models/limits.dart';
export 'src/models/rows.dart';
export 'src/models/schema.dart';
export 'src/models/sql.dart';
export 'src/value.dart';
export 'src/version.dart';

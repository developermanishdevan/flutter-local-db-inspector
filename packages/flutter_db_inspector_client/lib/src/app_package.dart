/// The running app's Dart package name (the `name:` in its pubspec.yaml),
/// derived from the isolate's root library. Saved queries are kept per app
/// under this name.
///
/// * `package:sfa_app/main.dart` (flutter run, debug sessions) → `sfa_app`
/// * `file:///…/sfa_app/lib/main_dev.dart` → `sfa_app` (the folder above
///   `lib/`)
/// * `org-dartlang-app:///lib/main.dart` (web) → the package of the app's own
///   libraries in [libraryUris], when one of them is
///   `package:<name>/main*.dart`
/// * anything else → the file name without `.dart`
///
/// Kept identical to `appPackage.ts` (VS Code) and `AppPackage.kt`.
String? appPackageOf(
  String? rootLibUri, [
  List<String> libraryUris = const [],
]) {
  if (rootLibUri == null || rootLibUri.isEmpty) return null;
  final fromPackage = _packageUri.firstMatch(rootLibUri);
  if (fromPackage != null) return fromPackage[1];
  final path = rootLibUri.replaceFirst(_scheme, '/').split(_queryOrFragment)[0];
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  final lib = segments.lastIndexOf('lib');
  if (lib > 0) return segments[lib - 1];
  final file =
      segments.isEmpty ? null : segments.last.replaceFirst(_dartSuffix, '');
  for (final uri in libraryUris) {
    final match = _mainLibrary.firstMatch(uri);
    if (match != null && (file == null || file.isEmpty || match[2] == file)) {
      return match[1];
    }
  }
  return file == null || file.isEmpty ? null : file;
}

final _packageUri = RegExp(r'^package:([^/]+)/');
final _scheme = RegExp(r'^[a-z-]+:/*', caseSensitive: false);
final _queryOrFragment = RegExp(r'[?#]');
final _dartSuffix = RegExp(r'\.dart$');
final _mainLibrary = RegExp(r'^package:([^/]+)/(main[^/]*)\.dart$');

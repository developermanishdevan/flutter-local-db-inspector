/**
 * The running app's Dart package name (the `name:` in its pubspec.yaml),
 * derived from the isolate's root library. Saved queries are kept per app
 * under this name.
 *
 * - `package:sfa_app/main.dart` (flutter run, debug sessions) → `sfa_app`
 * - `file:///…/sfa_app/lib/main_dev.dart` → `sfa_app` (the folder above `lib/`)
 * - `org-dartlang-app:///lib/main.dart` (web) → the package of the app's own
 *   libraries in [libraryUris], when one of them is `package:<name>/main*.dart`
 * - anything else → the file name without `.dart`
 *
 * Kept identical to `app_package.dart` (Dart client) and `AppPackage.kt`.
 */
export function appPackageOf(rootLibUri: string | undefined, libraryUris: readonly string[] = []): string | undefined {
  if (!rootLibUri) return undefined;
  const fromPackage = /^package:([^/]+)\//.exec(rootLibUri);
  if (fromPackage) return fromPackage[1];
  const path = rootLibUri.replace(/^[a-z-]+:\/*/i, '/').split(/[?#]/)[0];
  const segments = path.split('/').filter(Boolean);
  const lib = segments.lastIndexOf('lib');
  if (lib > 0) return segments[lib - 1];
  const file = segments[segments.length - 1]?.replace(/\.dart$/, '');
  for (const uri of libraryUris) {
    const match = /^package:([^/]+)\/(main[^/]*)\.dart$/.exec(uri);
    if (match && (!file || match[2] === file)) return match[1];
  }
  return file || undefined;
}

package com.manishdevan.flutterdb.connection

private val PACKAGE_URI = Regex("^package:([^/]+)/")
private val SCHEME_PREFIX = Regex("^[a-z-]+:/*", RegexOption.IGNORE_CASE)
private val QUERY_OR_FRAGMENT = Regex("[?#]")
private val MAIN_LIBRARY = Regex("^package:([^/]+)/(main[^/]*)\\.dart$")

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
 * Kept identical to `app_package.dart` (Dart client) and `appPackage.ts`.
 */
fun appPackageOf(rootLibUri: String?, libraryUris: List<String> = emptyList()): String? {
    if (rootLibUri.isNullOrEmpty()) return null
    PACKAGE_URI.find(rootLibUri)?.let { return it.groupValues[1] }
    val path = rootLibUri.replaceFirst(SCHEME_PREFIX, "/").split(QUERY_OR_FRAGMENT)[0]
    val segments = path.split('/').filter { it.isNotEmpty() }
    val lib = segments.lastIndexOf("lib")
    if (lib > 0) return segments[lib - 1]
    val file = segments.lastOrNull()?.removeSuffix(".dart")
    for (uri in libraryUris) {
        val match = MAIN_LIBRARY.find(uri) ?: continue
        if (file.isNullOrEmpty() || match.groupValues[2] == file) return match.groupValues[1]
    }
    return file?.takeIf { it.isNotEmpty() }
}

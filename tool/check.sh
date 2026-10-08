#!/usr/bin/env bash
# Formats, analyzes and tests every package, plus the VS Code extension and the
# Android Studio plugin.
#   tool/check.sh            # everything except native/network-heavy suites
#   tool/check.sh --all      # also Isar/ObjectBox/Realm native tests
set -euo pipefail
cd "$(dirname "$0")/.."

ALL=false
[[ "${1:-}" == "--all" ]] && ALL=true

dart_packages=(
  flutter_db_inspector_protocol
  flutter_db_inspector_core
  flutter_db_inspector_sqlite
  flutter_db_inspector_drift
  flutter_db_inspector_sembast
  flutter_db_inspector_hive
  flutter_db_inspector_client
)
native_packages=(
  flutter_db_inspector_isar
  flutter_db_inspector_objectbox
  flutter_db_inspector_realm
)
flutter_packages=(
  flutter_db_inspector_shared_preferences
  flutter_db_inspector_secure_storage
  flutter_db_inspector_get_storage
  flutter_db_inspector_devtools
  flutter_db_inspector
)

run() { echo "▶ $*"; "$@"; }

packages=("${dart_packages[@]}")
if $ALL; then
  packages+=("${native_packages[@]}")
  (cd packages/flutter_db_inspector_realm && dart pub get >/dev/null && dart run realm_dart install >/dev/null)
fi

for p in "${packages[@]}"; do
  (cd "packages/$p" && dart pub get >/dev/null &&
    run dart format --output=none --set-exit-if-changed lib test &&
    run dart analyze --fatal-infos &&
    run dart test)
done
for p in "${flutter_packages[@]}"; do
  (cd "packages/$p" && flutter pub get >/dev/null &&
    run dart format --output=none --set-exit-if-changed lib test &&
    run flutter analyze --fatal-infos &&
    run flutter test)
done
# The DevTools extension shipped inside flutter_db_inspector must stay valid.
(cd packages/flutter_db_inspector_devtools &&
  run dart run devtools_extensions validate --package=../flutter_db_inspector)
(cd examples/sqlite_example && flutter pub get >/dev/null && run flutter analyze --fatal-infos)

(cd integrations/vscode/flutter-db-inspector && npm ci >/dev/null &&
  run npm run typecheck && run npm run build && run npm run test:unit && run npm run test:integration)
# Android Studio / IntelliJ plugin (needs JDK 21: JAVA_HOME or Android Studio's bundled JBR).
AS_JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
if [[ -z "${JAVA_HOME:-}" && -d "$AS_JBR" ]]; then export JAVA_HOME="$AS_JBR"; fi
if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
  (cd integrations/android-studio/flutter-db-inspector &&
    run ./gradlew --no-daemon build buildPlugin verifyPluginProjectConfiguration)
else
  echo "⚠ skipping the Android Studio plugin: set JAVA_HOME to a JDK 21 (or install Android Studio)"
fi
echo "✔ all checks passed"

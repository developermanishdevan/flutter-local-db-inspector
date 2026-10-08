#!/usr/bin/env bash
# Copies the shared web UI (shared/web-ui/dist) into web/web_ui/, so that
# `flutter build web` (and `devtools_extensions build_and_copy`) serve it next
# to the extension at web_ui/index.html. web/web_ui/ is generated and not
# committed; the prebuilt extension under
# packages/flutter_db_inspector/extension/devtools/build/ is.
#
#   tool/sync_web_ui.sh              # npm ci (if needed) + production build + copy
#   tool/sync_web_ui.sh --no-build   # copy an existing shared/web-ui/dist
set -euo pipefail
cd "$(dirname "$0")/.."

ui=../../shared/web-ui
if [[ "${1:-}" != "--no-build" ]]; then
  [[ -d "$ui/node_modules" ]] || (cd "$ui" && npm ci)
  (cd "$ui" && npm run build:production)
fi
for f in index.html inspector.js inspector.css codicons/codicon.css codicons/codicon.ttf; do
  [[ -f "$ui/dist/$f" ]] || { echo "missing $ui/dist/$f: build shared/web-ui first" >&2; exit 1; }
done

rm -rf web/web_ui
mkdir -p web/web_ui/codicons
cp "$ui"/dist/{index.html,inspector.js,inspector.css} web/web_ui/
cp "$ui"/dist/codicons/{codicon.css,codicon.ttf} web/web_ui/codicons/
echo "✔ web/web_ui updated from shared/web-ui/dist"

#!/usr/bin/env bash
# Builds the upload bundle for deploy/native/install.sh: the committed repo
# (git archive HEAD) plus a release Web export with gzipped assets.
#
#   GODOT=/path/to/godot deploy/native/make_bundle.sh [out.tgz]
#
# Needs the Godot 4.7.2 Web export templates (web_nothreads_release.zip);
# deploy/fetch_web_templates.py installs just those.
set -euo pipefail

cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
OUT="${1:-build/trion-bundle.tgz}"
STAGE="build/bundle"

rm -rf "$STAGE" && mkdir -p "$STAGE/app" "$STAGE/web"
# Keep Godot from importing the staged copy of the project (duplicate classes).
touch build/.gdignore
git archive HEAD | tar -x -C "$STAGE/app"
"$GODOT" --headless --path . --export-release "Web" "$STAGE/web/index.html" >/dev/null 2>&1
test -s "$STAGE/web/index.wasm" || { echo "Web export failed" >&2; exit 1; }
gzip -k -9 "$STAGE"/web/*.wasm "$STAGE"/web/*.pck "$STAGE"/web/*.js "$STAGE"/web/*.html
tar -czf "$OUT" -C "$STAGE" app web
echo "bundle: $OUT ($(du -h "$OUT" | cut -f1)) from $(git rev-parse --short HEAD)"

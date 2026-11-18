#!/usr/bin/env bash
# Baut die Web-Fassung von Haven für den Seitenleisten-Eintrag in Home Assistant
# und legt sie in die Integration (custom_components/haven/frontend/).
#
#   tool/build_ha_panel.sh                 Version aus der manifest.json der Integration
#   tool/build_ha_panel.sh --version 0.4.0 Version fest vorgeben
#   tool/build_ha_panel.sh --out /pfad     anderer Zielordner
#   tool/build_ha_panel.sh --fake --out /tmp/x   mit Entwicklungsdaten (nur zum Testen)
#
# Die Version steht im Pfad (/haven_static/<version>/) und sorgt fürs Cache-Busting.
# Sie muss zur manifest.json der Integration passen, sonst findet HA die Dateien nicht.
set -euo pipefail

APP_DIR=$(cd "$(dirname "$0")/.." && pwd)
INTEGRATION_DIR=${HAVEN_INTEGRATION_DIR:-$APP_DIR/../integration}
OUT=""
VERSION=""
FAKE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --version) VERSION=$2; shift 2 ;;
    --fake) FAKE=true; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

MANIFEST="$INTEGRATION_DIR/custom_components/haven/manifest.json"
if [[ -z "$VERSION" ]]; then
  VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")
fi
# Wie panel.safe_version in der Integration.
VERSION=$(printf '%s' "$VERSION" | sed 's/[^0-9A-Za-z._-]/_/g')
OUT=${OUT:-$INTEGRATION_DIR/custom_components/haven/frontend}
BASE="/haven_static/$VERSION/"

if [[ "$FAKE" == true && "$OUT" == "$INTEGRATION_DIR"* ]]; then
  echo "Ein Build mit Entwicklungsdaten gehört nicht in die Integration (--out angeben)." >&2
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$APP_DIR"
DEFINES=()
[[ "$FAKE" == true ]] && DEFINES+=(--dart-define=HAVEN_FAKE=true)

echo "Baue Haven-Panel $VERSION (Basis $BASE)"
flutter build web --release \
  --no-web-resources-cdn \
  --no-source-maps \
  --no-wasm-dry-run \
  --base-href "$BASE" \
  "${DEFINES[@]}" \
  -o "$TMP/web"

W="$TMP/web"
# Nur eine CanvasKit (die volle, der Loader bekommt canvasKitVariant: "full").
rm -rf "$W/canvaskit/chromium" "$W/canvaskit/webparagraph"
rm -f "$W"/canvaskit/skwasm* "$W"/canvaskit/wimp* "$W"/canvaskit/*.symbols
# Kein Service Worker (veraltet, HA cacht über die Versions-URL), keine Maps.
rm -f "$W/flutter_service_worker.js" "$W"/*.map "$W/.last_build_id"
# flutter_scene legt in seine erzeugten Shader-Ordner ein .gitignore („*“).
# Im Repo der Integration fehlten die Shader dann (HACS lädt das Repo), und
# die 3D-Karte startete im Panel nicht. Die Dateien gehören ins Panel.
find "$W" -name .gitignore -delete
test -f "$W/assets/packages/flutter_scene/flutter_scene_generated/manifest.json" ||
  { echo "Shader von flutter_scene fehlen im Build." >&2; exit 1; }

test -f "$W/haven-panel.js" || { echo "haven-panel.js fehlt im Build (web/)." >&2; exit 1; }

mkdir -p "$OUT"
# Alten Stand ersetzen, aber nur Dateien dieses Builds behalten.
find "$OUT" -mindepth 1 -delete
cp -R "$W"/. "$OUT"/

echo "Fertig: $OUT"
du -sh "$OUT" | sed 's/^/Größe: /'
(cd "$OUT" && du -ah . | sort -rh | head -8)

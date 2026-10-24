#!/usr/bin/env bash
# Baut "Kev CAD.app" und legt sie in ~/Applications/Tools ab (Tools-Stapel im Dock).
#
#   ./build.sh              bauen und installieren: App nach ~/Applications/Tools, Kernel und Skill als eigene Kopie nach
#                           ~/Library/Application Support/de.upvis.kevcad/install (die installierte App hängt damit
#                           nicht am Arbeitsstand des Repos). Automatisch nach jedem neuen Stand auf main, siehe
#                           tools/auto-update.sh und .githooks/
#   ./build.sh --no-install nur bauen (build/Kev CAD.app)
#   ./build.sh --test [zusatz]
#                           Testvariante "Kev CAD Test" (mit Zusatz z. B. "Kev CAD Test ui") mit eigener Bundle-ID,
#                           eigenem Datenordner und Port; wird nicht installiert, Fenster öffnet auf dem zweiten Monitor
#   ./build.sh --core-tests nur die Tests von KevCADCore (swift test) und vom Kernel (pytest)
#
# Phase 4 (Referenzen aus Video und Fotos): Jeder Bau baut auch kevcad-capture (tools/capture, SwiftPM, Apple Object
# Capture) und frischt die Umgebung von fotomess auf (fotomess/.venv). Das Paket bringt beide mit (bin/kevcad-capture
# mit seinen Skripten, fotomess/ ohne Umgebung); die Installation legt sie unter install/bin und install/fotomess ab
# und baut dort die Umgebung von fotomess. Der Kernel findet sie neben sich (kevcad_kernel/referenz/ablage.py).
#
# Scan mit dem iPhone (SCAN.md, PLAN-SCAN.md): Jeder Bau frischt auch die Umgebung scan/ auf (kevscan: PromptDA mit
# torch, TSDF); das Paket bringt scan/ ohne Umgebung mit, die Installation legt install/scan an und baut dort die
# Umgebung aus uv.lock (offline möglich, solange der uv-Zwischenspeicher da ist). Die Gewichte von PromptDA sind nicht
# im Paket, sie laden beim ersten Gebrauch nach ~/Library/Caches/de.upvis.kevcad/promptda.
#
# Statik Stufe 4 (PLAN-STATIK.md): Die Installation richtet CalculiX auf der externen Platte UPVIS ULTRA ein, falls es
# fehlt ("/Volumes/UPVIS ULTRA/#PROGRAMME_DO-NOT-DELETE#/Kev CAD/calculix", micromamba und conda-forge, LIESMICH.txt
# dort). Fehlt die Platte, geht die Installation trotzdem durch.
#
# Für den Bau auf dem Mac mini (tools/fern.sh):
#   ./build.sh --bundle     Installationsbau ohne Installation: Paket build/bundle/ mit App, Kernel, Skill und VERSION
#   ./build.sh --install-bundle ORDNER
#                           ein solches Paket hier installieren (Kernel-Umgebung, Signatur, Tools-Stapel), ohne zu bauen
#   ./build.sh --icon       nur das App-Symbol erzeugen (braucht rsvg-convert, das dem Mini fehlt)
#
# Umgebung (nur für tools/fern.sh und Proben, sonst leer lassen):
#   KEVCAD_APP_REPO         Ordner mit kernel/.venv, den die App zur Laufzeit nimmt (Info.plist KevCADRepo); Vorgabe
#                           der Installationsordner bzw. bei --test/--no-install dieses Repo
#   KEVCAD_BUILD_NUMBER, KEVCAD_COMMIT_ID
#                           Buildnummer und Stand, wenn kein .git da ist (auf dem Mini)
#   KEVCAD_INSTALL_DIR, KEVCAD_INSTALL_ROOT
#                           andere Ziele der Installation (Probe von tools/auto-update.sh)
set -euo pipefail

cd "$(dirname "$0")"
REPO="$(pwd)"
MODE="${1:-}"

APP_NAME="Kev CAD"
# SK-CAD: sichtbarer Name; die App-Datei heißt weiter „Kev CAD.app“ (Pfade im Kernel, Prozessname)
DISPLAY_NAME="SK-CAD"
BUNDLE_ID="de.upvis.kevcad"
PORT=47823
if [ "$MODE" = "--test" ]; then
  SUFFIX="${2:-}"
  APP_NAME="Kev CAD Test${SUFFIX:+ $SUFFIX}"
  DISPLAY_NAME="SK-CAD Test${SUFFIX:+ $SUFFIX}"
  BUNDLE_ID="de.upvis.kevcad.test${SUFFIX:+.$SUFFIX}"
  # je Testvariante ein eigener Port, damit mehrere nebeneinander laufen können
  PORT=$((47824 + $(printf '%s' "$SUFFIX" | cksum | cut -d' ' -f1) % 100 * (${#SUFFIX} > 0)))
fi
INSTALL_DIR="${KEVCAD_INSTALL_DIR:-$HOME/Applications/Tools}"
INSTALL_ROOT="${KEVCAD_INSTALL_ROOT:-$HOME/Library/Application Support/de.upvis.kevcad/install}"
BUILD="$REPO/build"
BUNDLE="$BUILD/bundle"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

case "$MODE" in
  ""|--no-install|--test|--core-tests|--bundle|--install-bundle|--icon) ;;
  *) echo "Unbekannter Modus: $MODE (siehe Kopf von build.sh)"; exit 2 ;;
esac

# Installiert ein Paket aus build.sh --bundle: Kernel und Skill als eigene Kopie nach INSTALL_ROOT (mit eigener
# Python-Umgebung, die immer hier entsteht, weil sie absolute Pfade enthält), die App ad hoc signiert in den Tools-Stapel.
install_bundle() {
  local src="$1"
  for f in "$APP_NAME.app" kernel skill VERSION bin/kevcad-capture fotomess scan; do
    [ -e "$src/$f" ] || { echo "Paket unvollständig, $f fehlt in $src"; exit 1; }
  done
  echo "==> Kernel und Skill installieren nach $INSTALL_ROOT"
  mkdir -p "$INSTALL_ROOT"
  rsync -a --delete --exclude .venv --exclude __pycache__ --exclude .pytest_cache --exclude tests --exclude tools \
    "$src/kernel/" "$INSTALL_ROOT/kernel/"
  (cd "$INSTALL_ROOT/kernel" && uv sync -q --frozen --no-dev)
  rsync -a --delete "$src/skill/" "$INSTALL_ROOT/skill/"
  # Phase 4: kevcad-capture (Object Capture) und fotomess mit eigener Umgebung (Abhängigkeiten aus uv.lock)
  rsync -a --delete "$src/bin/" "$INSTALL_ROOT/bin/"
  rsync -a --delete --exclude .venv --exclude __pycache__ --exclude .pytest_cache "$src/fotomess/" \
    "$INSTALL_ROOT/fotomess/"
  (cd "$INSTALL_ROOT/fotomess" && uv sync -q --frozen --no-dev) \
    || echo "Achtung: Umgebung von fotomess nicht gebaut, referenz_vermessen geht nicht"
  # Scan: kevscan mit eigener Umgebung (torch, PromptDA, TSDF), nie im Kernel-Prozess
  rsync -a --delete --exclude .venv --exclude __pycache__ --exclude .pytest_cache "$src/scan/" "$INSTALL_ROOT/scan/"
  (cd "$INSTALL_ROOT/scan" && uv sync -q --frozen --no-dev) \
    || echo "Achtung: Umgebung von scan nicht gebaut, scan_importieren geht nicht"
  # Statik Stufe 4: CalculiX (GPL, eigenes Programm) auf der externen Platte UPVIS ULTRA unter
  # "#PROGRAMME_DO-NOT-DELETE#/Kev CAD/calculix" einrichten, falls es fehlt (einmalig, etwa 25 MB von conda-forge).
  # Nie fatal: Ohne Platte oder Netz meldet Stufe 4 das beim Gebrauch, S0 bis S3 laufen weiter.
  if [ -z "${KEVCAD_INSTALL_DIR:-}" ]; then
    "$INSTALL_ROOT/kernel/.venv/bin/python" -m kevcad_kernel.statik.ccx.installation --wenn-fehlt 2>&1 | tail -3 \
      || echo "Hinweis: CalculiX nicht eingerichtet (Statik Stufe 4 meldet es beim Gebrauch)"
  fi
  cp "$src/VERSION" "$INSTALL_ROOT/VERSION"

  echo "==> Installiere nach $INSTALL_DIR"
  # Hier signieren: Ein Paket vom Mac mini kommt per rsync, und die Signatur soll zu genau diesen Dateien passen.
  codesign --force --deep --sign - --timestamp=none "$src/$APP_NAME.app" >/dev/null 2>&1
  codesign --verify --deep "$src/$APP_NAME.app" || { echo "Signatur der App im Paket ungültig"; exit 1; }
  "$LSREGISTER" -u "$src/$APP_NAME.app" >/dev/null 2>&1 || true
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$src/$APP_NAME.app" "$INSTALL_DIR/"
  # Ohne das Zurücksetzen zeigt der Finder häufig noch das alte Symbol.
  touch "$INSTALL_DIR/$APP_NAME.app"
  if [ -n "${KEVCAD_INSTALL_DIR:-}" ]; then
    # Probe in einem anderen Ordner: nicht bei Launch Services anmelden, sonst startet `open -b de.upvis.kevcad` womöglich
    # diese Kopie statt Kevins App.
    "$LSREGISTER" -u "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1 || true
  else
    "$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1 || true
  fi
  echo "==> Fertig: $INSTALL_DIR/$APP_NAME.app (Stand, Build, Bauzeit: $(cat "$INSTALL_ROOT/VERSION"))"
  du -sh "$INSTALL_DIR/$APP_NAME.app"
}

if [ "$MODE" = "--install-bundle" ]; then
  [ -n "${2:-}" ] || { echo "Aufruf: ./build.sh --install-bundle ORDNER"; exit 2; }
  install_bundle "$(cd "$2" && pwd)"
  exit 0
fi

render_icon() {
  local icns="app/Resources/AppIcon.icns" iconset="$BUILD/AppIcon.iconset"
  mkdir -p app/Resources
  [ ! -f "$icns" ] || [ app/icon.svg -nt "$icns" ] || return 0
  if ! command -v rsvg-convert >/dev/null; then
    # Auf dem Mac mini fehlt rsvg-convert; tools/fern.sh erzeugt das Symbol vorher auf dem MacBook und spiegelt es mit.
    [ -f "$icns" ] && { echo "rsvg-convert fehlt, nehme das vorhandene Symbol"; return 0; }
    echo "rsvg-convert fehlt (brew install librsvg)"; exit 1
  fi
  rm -rf "$iconset" && mkdir -p "$iconset"
  render() { rsvg-convert -w "$1" -h "$1" app/icon.svg -o "$iconset/$2"; }
  render 16 icon_16x16.png
  render 32 icon_16x16@2x.png
  render 32 icon_32x32.png
  render 64 icon_32x32@2x.png
  render 128 icon_128x128.png
  render 256 icon_128x128@2x.png
  render 256 icon_256x256.png
  render 512 icon_256x256@2x.png
  render 512 icon_512x512.png
  render 1024 icon_512x512@2x.png
  iconutil -c icns "$iconset" -o "$icns"
  rm -rf "$iconset"
}

if [ "$MODE" = "--icon" ]; then
  render_icon
  exit 0
fi

BUILD_NUMBER=${KEVCAD_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
if [ -n "${KEVCAD_COMMIT_ID+x}" ]; then
  COMMIT="$KEVCAD_COMMIT_ID"
else
  COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "")
  [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] && COMMIT="$COMMIT+"
fi

echo "==> Kernel-Umgebung"
command -v uv >/dev/null || { echo "uv fehlt (https://docs.astral.sh/uv/)"; exit 1; }
(cd kernel && uv sync -q)
echo "==> fotomess-Umgebung"
(cd fotomess && uv sync -q) || echo "Achtung: Umgebung von fotomess nicht gebaut"
echo "==> scan-Umgebung (Kev Scan auswerten)"
(cd scan && uv sync -q) || echo "Achtung: Umgebung von scan nicht gebaut"

if [ "$MODE" = "--core-tests" ]; then
  echo "==> Tests KevCADCore"
  # Zusammenfassung von XCTest und Fehlerzeilen; der Exit-Code von swift test kommt über pipefail durch
  (cd app/KevCADCore && swift test 2>&1 | { grep -E "error:|failed|Executed [0-9]+ tests" || true; } | tail -15)
  echo "==> Tests Kernel"
  (cd kernel && .venv/bin/python -m pytest -q)
  exit 0
fi

echo "==> kevcad-capture (Object Capture)"
swift build -c release --package-path tools/capture -q 2>&1 | grep -E "error|warning: unre" || true
[ -x tools/capture/.build/release/kevcad-capture ] || { echo "kevcad-capture ließ sich nicht bauen"; exit 1; }

echo "==> Icon"
render_icon

# Welchen Kernel die App zur Laufzeit startet: die installierte Kopie oder (Test, nur bauen) dieses Repo.
if [ -z "$MODE" ] || [ "$MODE" = "--bundle" ]; then
  APP_REPO="${KEVCAD_APP_REPO:-$INSTALL_ROOT}"
else
  APP_REPO="${KEVCAD_APP_REPO:-$REPO}"
fi

echo "==> Xcode-Projekt erzeugen"
command -v xcodegen >/dev/null || { echo "xcodegen fehlt (brew install xcodegen)"; exit 1; }
xcodegen generate --spec app/project.yml --quiet

echo "==> Kompiliere ($APP_NAME)"
mkdir -p "$BUILD"
LOG="$BUILD/xcodebuild.log"
if ! xcodebuild -project app/KevCAD.xcodeproj -scheme KevCAD -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath "$BUILD/DerivedData" \
  KEVCAD_APP_NAME="$APP_NAME" KEVCAD_DISPLAY_NAME="$DISPLAY_NAME" KEVCAD_BUNDLE_ID="$BUNDLE_ID" KEVCAD_REPO="$APP_REPO" KEVCAD_PORT="$PORT" \
  KEVCAD_BUILD="$BUILD_NUMBER" KEVCAD_COMMIT="$COMMIT" \
  build -quiet > "$LOG" 2>&1; then
  grep -E "error:|\*\* BUILD FAILED" "$LOG" | grep -v "^Failed frontend" | head -30
  echo "Build fehlgeschlagen, vollständiges Protokoll: $LOG"
  exit 1
fi

SRC="$BUILD/DerivedData/Build/Products/Release/$APP_NAME.app"
[ -d "$SRC" ] || { echo "Build fehlgeschlagen: $SRC fehlt"; exit 1; }
rm -rf "$BUILD/$APP_NAME.app"
cp -R "$SRC" "$BUILD/$APP_NAME.app"
APP="$BUILD/$APP_NAME.app"
# SK-CAD: Finder, Dock und Menü zeigen den lokalisierten Namen; Info.plist behält „Kev CAD“ als Dateinamen-Gegenstück.
for lp in de en; do
  mkdir -p "$APP/Contents/Resources/$lp.lproj"
  printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$DISPLAY_NAME" "$DISPLAY_NAME" \
    > "$APP/Contents/Resources/$lp.lproj/InfoPlist.strings"
done
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1
# Build-Kopien bei Launch Services abmelden, sonst startet `open -b de.upvis.kevcad` womöglich eine davon statt der
# installierten App.
"$LSREGISTER" -u "$SRC" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

if [ "$MODE" = "--no-install" ] || [ "$MODE" = "--test" ]; then
  echo "==> Fertig (nicht installiert): $APP (Bundle-ID $BUNDLE_ID, MCP-Port $PORT)"
  exit 0
fi

# Paket aus App, Kernel, Skill und VERSION: dasselbe, ob es hier installiert wird oder vom Mac mini kommt.
echo "==> Paket $BUNDLE"
rm -rf "$BUNDLE" && mkdir -p "$BUNDLE"
cp -R "$APP" "$BUNDLE/"
"$LSREGISTER" -u "$BUNDLE/$APP_NAME.app" >/dev/null 2>&1 || true
# Ohne leere Ordner (-m): Ein Ordner, in dem nach einem Zweigwechsel nur __pycache__ übrig ist, wäre im installierten
# Kernel ein importierbares leeres Paket.
rsync -a -m --exclude .venv --exclude __pycache__ --exclude .pytest_cache --exclude tests --exclude tools \
  kernel/ "$BUNDLE/kernel/"
rsync -a -m --exclude .DS_Store skill/ "$BUNDLE/skill/"
mkdir -p "$BUNDLE/bin"
cp tools/capture/.build/release/kevcad-capture "$BUNDLE/bin/"
cp tools/capture/scripts/*.py "$BUNDLE/bin/"  # Kontrollbilder (Blender), sucht das Programm neben sich
rsync -a -m --exclude .venv --exclude __pycache__ --exclude .pytest_cache --exclude tests --exclude benchmark \
  --exclude .DS_Store fotomess/ "$BUNDLE/fotomess/"
rsync -a -m --exclude .venv --exclude __pycache__ --exclude .pytest_cache --exclude tests --exclude .DS_Store \
  scan/ "$BUNDLE/scan/"
printf '%s %s %s\n' "$COMMIT" "$BUILD_NUMBER" "$(date '+%Y-%m-%d %H:%M')" > "$BUNDLE/VERSION"

if [ "$MODE" = "--bundle" ]; then
  echo "==> Fertig (Paket, nicht installiert): $BUNDLE (Build $BUILD_NUMBER, $COMMIT, KevCADRepo $APP_REPO)"
  exit 0
fi

install_bundle "$BUNDLE"

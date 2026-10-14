#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/src/macOS"
SWIFT_ARGS=()
if [ -n "${CODEX_SWITCH_BUILD_PATH:-}" ]; then SWIFT_ARGS+=(--scratch-path "$CODEX_SWITCH_BUILD_PATH"); fi
swift test "${SWIFT_ARGS[@]}"
swift build -c release "${SWIFT_ARGS[@]}"
BIN="$(swift build -c release --show-bin-path "${SWIFT_ARGS[@]}")"
OUTPUT="${CODEX_SWITCH_OUTPUT_DIR:-$ROOT/dist/macos}"
APP="$OUTPUT/Codex Switch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CodexSwitch" "$APP/Contents/MacOS/CodexSwitch"
# Include SwiftPM resources; the limiter must also work away from the build machine.
for RESOURCE in "$BIN"/*.bundle; do
  [ -d "$RESOURCE" ] || continue
  ditto "$RESOURCE" "$APP/Contents/Resources/$(basename "$RESOURCE")"
done
if [ -n "${MIHOMO_BINARY:-}" ]; then
  cp "$MIHOMO_BINARY" "$APP/Contents/Resources/mihomo"
  chmod +x "$APP/Contents/Resources/mihomo"
  codesign --force --sign - "$APP/Contents/Resources/mihomo"
  { "$MIHOMO_BINARY" -v; echo 'Source and license: https://github.com/MetaCubeX/mihomo (GPL-3.0)'; } > "$APP/Contents/Resources/MIHOMO-SOURCE.txt"
  if [ -n "${MIHOMO_LICENSE:-}" ]; then cp "$MIHOMO_LICENSE" "$APP/Contents/Resources/MIHOMO-LICENSE"; fi
fi
ICONSET="$OUTPUT/CodexSwitch.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/assets/app-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/assets/app-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/CodexSwitch.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CodexSwitch</string>
  <key>CFBundleIdentifier</key><string>local.codexswitch.app</string>
  <key>CFBundleName</key><string>Codex Switch</string>
  <key>CFBundleIconFile</key><string>CodexSwitch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.5</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP (local ad-hoc signature; not notarized)"

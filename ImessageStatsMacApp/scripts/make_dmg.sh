#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="${WEB_DIR:-/Users/jz/Vibe coding/Imessaging}"
UPDATES_DIR="$WEB_DIR/updates"
APP_NAME="ImessageStatsMacApp"
APP_BUNDLE="$ROOT_DIR/dist/${APP_NAME}.app"

DMG_LATEST_NAME="iMessages-Stats.dmg"

cd "$ROOT_DIR"

"$ROOT_DIR/build_app.sh"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "App bundle not found at: $APP_BUNDLE" >&2
  exit 1
fi

mkdir -p "$UPDATES_DIR"

SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "1.0")

DMG_VERSIONED_NAME="iMessages-Stats-${SHORT_VERSION}.dmg"
DMG_LATEST_PATH="$UPDATES_DIR/$DMG_LATEST_NAME"
DMG_VERSIONED_PATH="$UPDATES_DIR/$DMG_VERSIONED_NAME"

STAGE_DIR="$ROOT_DIR/.dmg_stage"
DMG_APP_NAME="iMessages Stats.app"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_BUNDLE" "$STAGE_DIR/$DMG_APP_NAME"

VOLICON_PATH="$STAGE_DIR/$DMG_APP_NAME/Contents/Resources/AppIcon.icns"

# Emulate an overwrite flag.
rm -f "$DMG_VERSIONED_PATH" "$DMG_LATEST_PATH"

output="create-dmg not installed"
if command -v create-dmg >/dev/null 2>&1; then
  CREATE_DMG_CMD=(create-dmg
    --sandbox-safe
    --skip-jenkins
    --volname "iMessages Stats"
    --volicon "$VOLICON_PATH"
    --window-size 660 400
    --icon-size 128
    --icon "$DMG_APP_NAME" 180 170
    --hide-extension "$DMG_APP_NAME"
    --app-drop-link 480 170
    "$DMG_VERSIONED_PATH"
    "$STAGE_DIR"
  )

  if output="$("${CREATE_DMG_CMD[@]}" 2>&1)"; then
    cp -f "$DMG_VERSIONED_PATH" "$DMG_LATEST_PATH"
    echo "DMG created:"
    echo "- $DMG_VERSIONED_PATH"
    echo "- $DMG_LATEST_PATH"
    exit 0
  fi
fi

# In sandboxed environments, hdiutil may be unable to start its helper daemon
# (error: "Cannot start hdiejectd because app is sandboxed"). create-dmg then fails.
# Fall back to a basic, functional DMG built via makehybrid. It will still contain
# the app (with its icon), but won't have the Finder window layout / volume icon.
echo "$output" >&2
echo "create-dmg failed; trying fallback DMG build (hdiutil makehybrid)..." >&2

ln -s /Applications "$STAGE_DIR/Applications" 2>/dev/null || true

TMP_HYBRID="$ROOT_DIR/.tmp/hybrid-$SHORT_VERSION.dmg"
rm -f "$TMP_HYBRID" "$DMG_VERSIONED_PATH" "$DMG_LATEST_PATH"

# Best-effort volume icon for the hybrid image: Finder uses .VolumeIcon.icns when the
# volume root has the custom icon attribute.
if [[ -f "$VOLICON_PATH" ]]; then
  cp -f "$VOLICON_PATH" "$STAGE_DIR/.VolumeIcon.icns"
  /usr/bin/SetFile -c icnC "$STAGE_DIR/.VolumeIcon.icns" 2>/dev/null || true
  /usr/bin/SetFile -a C "$STAGE_DIR" 2>/dev/null || true
fi

hdiutil makehybrid -hfs -default-volume-name "iMessages Stats" -o "$TMP_HYBRID" "$STAGE_DIR" >/dev/null

# Compress to a standard UDZO DMG when possible.
hdiutil convert -format UDZO -ov -o "$DMG_VERSIONED_PATH" "$TMP_HYBRID" >/dev/null || cp -f "$TMP_HYBRID" "$DMG_VERSIONED_PATH"
rm -f "$TMP_HYBRID"

cp -f "$DMG_VERSIONED_PATH" "$DMG_LATEST_PATH"
echo "DMG created (fallback):"
echo "- $DMG_VERSIONED_PATH"
echo "- $DMG_LATEST_PATH"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="/Users/jz/Vibe coding/Imessaging"
UPDATES_DIR="$WEB_DIR/updates"
APP_NAME="ImessageStatsMacApp"
APP_BUNDLE="$ROOT_DIR/dist/${APP_NAME}.app"
APPCAST_PATH="$WEB_DIR/appcast.xml"
PRIVATE_KEY_FILE="$ROOT_DIR/SparkleKeys/ed25519_private.key"
FEED_URL="https://jz1324.github.io/Imessaging/appcast.xml"
DOWNLOAD_URL_PREFIX="https://jz1324.github.io/Imessaging/updates"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
  echo "Missing Sparkle private key at: $PRIVATE_KEY_FILE" >&2
  exit 1
fi

"$ROOT_DIR/build_app.sh"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "App bundle not found at: $APP_BUNDLE" >&2
  exit 1
fi

# Ensure the app is signed (ad-hoc by default for local testing)
/usr/bin/codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE" 2>/dev/null || true

mkdir -p "$UPDATES_DIR"

SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_BUNDLE/Contents/Info.plist")
MIN_SYSTEM_VERSION=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "13.0")

ZIP_NAME="${APP_NAME}-${SHORT_VERSION}.zip"
ZIP_PATH="$UPDATES_DIR/$ZIP_NAME"

rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# Optional DMG for manual download (Sparkle still uses the ZIP).
# Use the dedicated DMG script which can fall back when create-dmg/hdiutil can't do the fancy layout.
"$ROOT_DIR/scripts/make_dmg.sh" >/dev/null 2>&1 || true

DMG_LATEST_PATH="$UPDATES_DIR/iMessages-Stats.dmg"
if [[ ! -f "$DMG_LATEST_PATH" ]]; then
  echo "Missing DMG at: $DMG_LATEST_PATH" >&2
  exit 1
fi

# Use the stable DMG URL for Sparkle updates to avoid GitHub Pages propagation issues
# when versioned filenames are introduced. Manual downloads can still use versioned DMGs.
SIGN_OUTPUT=$(/Users/jz/Vibe\ coding/ImessageStatsMacApp/tools/sparkle/bin/sign_update --ed-key-file "$PRIVATE_KEY_FILE" "$DMG_LATEST_PATH")
SIG=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LEN=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')

if [[ -z "$SIG" || -z "$LEN" ]]; then
  echo "Failed to sign update." >&2
  exit 1
fi

PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
    xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>iMessages Stats Updates</title>
    <link>https://jz1324.github.io/Imessaging/</link>
    <description>Updates for iMessages Stats</description>
    <language>en</language>
    <item>
      <title>Version ${SHORT_VERSION}</title>
      <sparkle:version>${BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="${DOWNLOAD_URL_PREFIX}/iMessages-Stats.dmg"
        length="${LEN}"
        type="application/octet-stream"
        sparkle:edSignature="${SIG}"
        sparkle:os="macos" />
    </item>
  </channel>
</rss>
XML

echo "Release ready (not pushed):"
echo "- App: $APP_BUNDLE"
echo "- Zip: $ZIP_PATH"
echo "- Appcast: $APPCAST_PATH"
DMG_LATEST_PATH="$UPDATES_DIR/iMessages-Stats.dmg"
DMG_VERSIONED_PATH="$UPDATES_DIR/iMessages-Stats-${SHORT_VERSION}.dmg"
if [[ -f "$DMG_VERSIONED_PATH" ]]; then
  echo "- DMG: $DMG_VERSIONED_PATH"
fi
if [[ -f "$DMG_LATEST_PATH" ]]; then
  echo "- DMG (latest): $DMG_LATEST_PATH"
fi

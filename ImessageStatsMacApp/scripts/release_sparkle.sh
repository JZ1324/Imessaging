#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/ImessageStatsMacApp.app"
RELEASES_DIR="$ROOT_DIR/releases"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT_DIR/tools/sparkle/bin}"
APPCAST_BASE_URL="${APPCAST_BASE_URL:-https://example.com/imessagestats}" # change to your real hosting URL

mkdir -p "$RELEASES_DIR"

if [[ ! -x "$SPARKLE_TOOLS_DIR/generate_appcast" ]]; then
  echo "Sparkle tools not found at $SPARKLE_TOOLS_DIR."
  echo "Download Sparkle and ensure generate_appcast is available."
  exit 1
fi

# Build app with Sparkle feed URL
export SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-$APPCAST_BASE_URL/appcast.xml}"
"$ROOT_DIR/build_app.sh"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App not found at $APP_DIR"
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_DIR/Contents/Info.plist")
ARCHIVE_NAME="iMessagesStats-${VERSION}.zip"
ARCHIVE_PATH="$RELEASES_DIR/$ARCHIVE_NAME"

# Zip app
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"

# Optional release notes stub
NOTES_PATH="$RELEASES_DIR/iMessagesStats-${VERSION}.html"
if [[ ! -f "$NOTES_PATH" ]]; then
  cat > "$NOTES_PATH" <<EOF
<h2>iMessages Stats ${VERSION}</h2>
<ul>
  <li>Changes go here.</li>
</ul>
EOF
fi

# Generate appcast (signs with your keychain ed25519 key)
"$SPARKLE_TOOLS_DIR/generate_appcast" --download-url-prefix "$APPCAST_BASE_URL" "$RELEASES_DIR"

echo "\nRelease ready:"
echo "- $ARCHIVE_PATH"
echo "- $RELEASES_DIR/appcast.xml"
echo "Upload both to: $APPCAST_BASE_URL"
echo "Build: $BUILD"

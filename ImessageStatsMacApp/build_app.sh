#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/ImessageStatsMacApp.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
ICON_SOURCE="${ICON_SOURCE:-/Users/jz/Vibe coding/Imessaging/Imessengericon.png}"
ICON_NAME="AppIcon"
APP_VERSION="${APP_VERSION:-1.0.48}"
APP_BUILD="${APP_BUILD:-49}"
SPARKLE_PUBLIC_KEY="TU8OYlQiOjkEnk2rPiNe5P4t9SnvkWUeH/82TpuDLOo="
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://jz1324.github.io/Imessaging/appcast.xml}"

cd "$ROOT_DIR"

mkdir -p "$ROOT_DIR/dist"

# SwiftPM may attempt to use sandbox-exec and module caches under ~/.cache.
# Keep caches inside the repo so builds work in restricted environments too.
mkdir -p "$ROOT_DIR/.tmp/clang-module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.tmp/clang-module-cache"

swift build -c release --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$FRAMEWORKS_DIR"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>ImessageStatsMacApp</string>
  <key>CFBundleDisplayName</key>
  <string>iMessages Stats</string>
  <key>CFBundleIdentifier</key>
  <string>com.imessages.stats</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>ImessageStatsMacApp</string>
  <key>CFBundleIconFile</key>
  <string>${ICON_NAME}.icns</string>
  <key>CFBundleIconName</key>
  <string>${ICON_NAME}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSContactsUsageDescription</key>
  <string>We use your contacts to show names and photos instead of phone numbers in stats.</string>
  <key>SUFeedURL</key>
  <string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key>
  <string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.imessages.stats.auth</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>imessagestats</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

cp "$BUILD_DIR/ImessageStatsMacApp" "$MACOS_DIR/ImessageStatsMacApp"
chmod +x "$MACOS_DIR/ImessageStatsMacApp"

# Build app icon from PNG (if present)
if [[ -f "$ICON_SOURCE" ]]; then
  python3 "$ROOT_DIR/tools/png_to_icns.py" "$ICON_SOURCE" "$RES_DIR/${ICON_NAME}.icns" || {
    echo "Warning: failed to generate icns from $ICON_SOURCE" >&2
  }
else
  echo "Warning: icon source not found at $ICON_SOURCE" >&2
fi

# Embed Sparkle.framework so the app runs outside the build tree
SPARKLE_SRC="$ROOT_DIR/.build/arm64-apple-macosx/release/Sparkle.framework"
if [[ -d "$SPARKLE_SRC" ]]; then
  rsync -a --delete "$SPARKLE_SRC" "$FRAMEWORKS_DIR/"
  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/ImessageStatsMacApp" 2>/dev/null || true
fi

# Sign the app bundle for local development
codesign --force --deep --sign - "$APP_DIR"

printf "\nApp built at: %s\n" "$APP_DIR"

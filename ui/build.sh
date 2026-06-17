#!/usr/bin/env bash
# Build EmojiSwapUI.swift into a runnable EmojiSwap.app bundle.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/EmojiSwap.app"
BIN="$APP/Contents/MacOS/EmojiSwap"

echo "compiling …"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# -parse-as-library is required so the SwiftUI @main entry point is used.
swiftc -O -parse-as-library \
  -framework SwiftUI -framework AppKit \
  -o "$BIN" "$DIR/EmojiSwapUI.swift"

# app icon: blended side-view pig 🐖 (Noto front half + realistic back half, blend-pig.png)
[ -f "$DIR/AppIcon.icns" ] && cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>EmojiSwap</string>
  <key>CFBundleDisplayName</key><string>EmojiSwap</string>
  <key>CFBundleIdentifier</key><string>com.emojiswap.ui</string>
  <key>CFBundleExecutable</key><string>EmojiSwap</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Pre-render the default-preview glyphs (one per category) for each set and bundle
# them, so the running app shows the default preview with no font download. This is
# a BUILD-time fetch only; the shipped app downloads a set's font solely on demand.
echo "pre-rendering bundled preview glyphs …"
for s in noto noto-mono twemoji openmoji emojitwo blobmoji tossface \
         fluent fluent-flat fluent-mono; do
  "$DIR/../emojiswap" download "$s" >/dev/null 2>&1 || true   # best-effort; skips ones not yet released
done
rm -rf "$APP/Contents/Resources/preview"; mkdir -p "$APP/Contents/Resources/preview"
swift "$DIR/genpreviews.swift" "$APP/Contents/Resources/preview" || true

echo "built: $APP"
echo "run:   open \"$APP\"    (or: \"$BIN\")"

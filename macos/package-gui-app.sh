#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DirtyTest"
APP_DIR="$ROOT_DIR/dist/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BINARY_NAME="dirtytest-gui"
APP_BUNDLE_ID="io.github.ndtest.unofficial"
APP_VERSION="1.0.0"

cd "$ROOT_DIR"
swift build -c release --product "$BINARY_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Build .icns from AppIcon.png
ICON_SRC="$ROOT_DIR/AppIcon.png"
ICONSET_DIR="$ROOT_DIR/AppIcon.iconset"
if [[ -f "$ICON_SRC" ]]; then
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"
    for size in 16 32 64 128 256 512; do
        sips -z $size $size "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}.png"       > /dev/null
        sips -z $((size*2)) $((size*2)) "$ICON_SRC" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" > /dev/null
    done
    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
    echo "App icon created: $RESOURCES_DIR/AppIcon.icns"
else
    echo "Warning: AppIcon.png not found at $ICON_SRC — skipping icon"
fi

cp "$ROOT_DIR/.build/release/$BINARY_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DirtyTest</string>
    <key>CFBundleDisplayName</key>
    <string>DirtyTest</string>
    <key>CFBundleExecutable</key>
    <string>DirtyTest</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleGetInfoString</key>
    <string>Unofficial macOS fork of Naraeon Dirty Test. The developer assumes no responsibility for any side effects caused by this program. See GPL 3.0 for details.</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "Created app bundle: $APP_DIR"

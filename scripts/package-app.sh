#!/usr/bin/env bash
# Build release binary and assemble dist/Quill.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-1.1.0}"
BUNDLE_ID="${BUNDLE_ID:-com.citedy.quill.menubar}"
DIST="$ROOT/dist"
APP="$DIST/Quill.app"

echo "→ swift build -c release"
swift build -c release

BIN="$ROOT/.build/release/quill"
test -x "$BIN"

echo "→ assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Quill</string>
	<key>CFBundleExecutable</key>
	<string>quill</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Quill</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Quill records your microphone as one track of a meeting.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Quill records system audio (the other side of the call) as a separate track.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$BIN" "$APP/Contents/MacOS/quill"
chmod 755 "$APP/Contents/MacOS/quill"
codesign --force --deep --sign - "$APP"

echo "→ $APP ready ($(du -h "$APP/Contents/MacOS/quill" | awk '{print $1}'))"

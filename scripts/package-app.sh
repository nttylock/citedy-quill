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

# Prefer Developer ID so TCC (mic + system audio) survives rebuilds.
# Ad-hoc (`-`) changes CDHash every build → macOS re-prompts every launch.
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | rg -q "Developer ID Application"; then
    SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
  elif security find-identity -v -p codesigning 2>/dev/null | rg -q "Apple Development"; then
    SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
  else
    SIGN_ID="-"
  fi
fi

echo "→ codesign identity: $SIGN_ID"
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  # Entitlements for mic under hardened runtime when using a real identity.
  ENTITLEMENTS="$DIST/Quill.entitlements"
  cat > "$ENTITLEMENTS" <<'ENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
ENTS
  codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_ID" \
    "$APP"
fi

echo "→ $APP ready ($(du -h "$APP/Contents/MacOS/quill" | awk '{print $1}')) signed as $SIGN_ID"

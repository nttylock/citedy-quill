#!/usr/bin/env bash
# Create a drag-to-Applications DMG in dist/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-1.1.0}"
DIST="$ROOT/dist"
APP="$DIST/Quill.app"
DMG="$DIST/Quill-${VERSION}.dmg"
STAGE="$DIST/dmg-stage"

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/package-app.sh"
fi

echo "→ stage DMG contents"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Quill.app"
ln -s /Applications "$STAGE/Applications"

# Optional readme inside DMG
cat > "$STAGE/README.txt" <<EOF
Quill ${VERSION}
================

1. Drag Quill.app to Applications
2. Open Quill (menu bar shows "Quill")
3. Configure OpenAI key:

   mkdir -p ~/.config/quill
   echo 'OPENAI_API_KEY=sk-...' > ~/.config/quill/env
   chmod 600 ~/.config/quill/env

Optional config: ~/.config/quill/config.json
See https://github.com/nttylock/citedy-quill
EOF

echo "→ create $DMG"
hdiutil create \
  -volname "Quill ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGE"
ls -lh "$DMG"
echo "→ done: $DMG"

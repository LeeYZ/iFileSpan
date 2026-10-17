#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="$(xcode-select -p)"
ICTOOL="$DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"
ICON_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ifilespan-icon.XXXXXX")"
trap 'rm -rf "$ICON_TEMP"' EXIT
mkdir -p "$ICON_TEMP/Assets.xcassets" "$ICON_TEMP/compiled" "$PROJECT_DIR/IconResources"
cat > "$ICON_TEMP/Assets.xcassets/Contents.json" <<'JSON'
{"info":{"author":"xcode","version":1}}
JSON
xcrun actool --compile "$ICON_TEMP/compiled" --platform macosx --minimum-deployment-target 15.0 \
    --app-icon AppIcon --include-all-app-icons --output-partial-info-plist "$ICON_TEMP/icon-info.plist" \
    "$ICON_TEMP/Assets.xcassets" "$PROJECT_DIR/AppIcon.icon"
"$ICTOOL" "$PROJECT_DIR/AppIcon.icon" --export-image --output-file "$PROJECT_DIR/Assets/iFileSpan-icon.png" \
    --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
cp "$ICON_TEMP/compiled/AppIcon.icns" "$PROJECT_DIR/AppIcon.icns"
cp "$ICON_TEMP/compiled/Assets.car" "$PROJECT_DIR/IconResources/Assets.car"

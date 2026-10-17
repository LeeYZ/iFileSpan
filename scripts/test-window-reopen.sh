#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ifilespan-window-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
DEVELOPER_PATH="$(xcode-select -p)"
SDK="$DEVELOPER_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
APP_DIR="$TEST_DIR/WindowReopenTest.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowReopenTest</string>
<key>CFBundleIdentifier</key><string>local.ifilespan.window-reopen-test</string>
<key>CFBundleName</key><string>WindowReopenTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
"$DEVELOPER_PATH/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
    -parse-as-library -Xfrontend -disable-sandbox -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$TEST_DIR/cache" \
    "$PROJECT_DIR/Sources/iFileSpan/ApplicationLifecycle.swift" \
    "$PROJECT_DIR/scripts/WindowReopenTest.swift" \
    -o "$APP_DIR/Contents/MacOS/WindowReopenTest"
"$APP_DIR/Contents/MacOS/WindowReopenTest"

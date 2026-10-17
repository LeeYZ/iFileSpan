#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:?请传入已构建的 iFileSpan.app 路径}"
VENDOR_DIR="$PROJECT_DIR/Vendor"
DEVELOPER_PATH="$(xcode-select -p)"
TOOLS="$DEVELOPER_PATH/Toolchains/XcodeDefault.xctoolchain/usr/bin"
OTOOL="$TOOLS/llvm-otool"
INSTALL_NAME_TOOL="$TOOLS/install_name_tool"
mkdir -p "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources/ThirdParty"
cp -R "$VENDOR_DIR/Frameworks/" "$APP_DIR/Contents/Frameworks/"
cp -R "$VENDOR_DIR/Licenses" "$VENDOR_DIR/Sources" "$VENDOR_DIR/manifest.json" "$APP_DIR/Contents/Resources/ThirdParty/"
cp "$PROJECT_DIR/THIRD_PARTY.md" "$APP_DIR/Contents/Resources/ThirdParty/README.md"
for LIBRARY in "$APP_DIR/Contents/Frameworks/"*.dylib; do
    [ -L "$LIBRARY" ] && continue
    "$INSTALL_NAME_TOOL" -id "@rpath/$(basename "$LIBRARY")" "$LIBRARY"
    while IFS= read -r DEPENDENCY; do
        case "$DEPENDENCY" in
            /usr/lib/*|/System/Library/*) continue ;;
        esac
        BASENAME="${DEPENDENCY##*/}"
        if [ -f "$APP_DIR/Contents/Frameworks/$BASENAME" ]; then
            "$INSTALL_NAME_TOOL" -change "$DEPENDENCY" "@loader_path/$BASENAME" "$LIBRARY"
        else
            echo "无法在安装包中找到依赖：$DEPENDENCY" >&2
            exit 1
        fi
    done < <("$OTOOL" -L "$LIBRARY" | /usr/bin/awk 'NR>1 {print $1}')
    xattr -c "$LIBRARY"
    codesign --force --sign - "$LIBRARY"
done

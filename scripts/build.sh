#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-$PROJECT_DIR/dist}"
BUILD_DIR="${DEVICEFILES_BUILD_DIR:-$PROJECT_DIR/.build/manual}"
mkdir -p "$DESTINATION" "$BUILD_DIR/tmp" "$BUILD_DIR/cache" "$BUILD_DIR/DeviceBridge"
export TMPDIR="$BUILD_DIR/tmp/"
DEVELOPER_PATH="$(xcode-select -p)"
SDK="$DEVELOPER_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
SWIFTC="$DEVELOPER_PATH/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
CLANG="$DEVELOPER_PATH/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
ARCH="${DEVICEFILES_ARCH:-$(uname -m)}"
cp "$PROJECT_DIR/Sources/DeviceBridge/include/DeviceBridge.h" "$BUILD_DIR/DeviceBridge/"
printf 'module DeviceBridge { header "DeviceBridge.h" export * }\n' > "$BUILD_DIR/DeviceBridge/module.modulemap"
"$CLANG" -c "$PROJECT_DIR/Sources/DeviceBridge/DeviceBridge.c" -O2 -arch "$ARCH" -mmacosx-version-min=14.0 \
    -isysroot "$SDK" -I "$BUILD_DIR/DeviceBridge" -o "$BUILD_DIR/DeviceBridge.o"
"$SWIFTC" -parse-as-library -emit-object -emit-module -whole-module-optimization -O \
    -module-name DeviceCore -module-cache-path "$BUILD_DIR/cache" -sdk "$SDK" \
    -I "$BUILD_DIR/DeviceBridge" -target "$ARCH-apple-macosx14.0" \
    "$PROJECT_DIR"/Sources/DeviceCore/*.swift -o "$BUILD_DIR/DeviceCore.o" \
    -emit-module-path "$BUILD_DIR/DeviceCore.swiftmodule"
APP_DIR="$DESTINATION/iFileSpan.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
"$SWIFTC" -parse-as-library -Xfrontend -disable-sandbox -O -module-name iFileSpan -module-cache-path "$BUILD_DIR/cache" -sdk "$SDK" \
    -I "$BUILD_DIR" -I "$BUILD_DIR/DeviceBridge" -target "$ARCH-apple-macosx14.0" \
    "$PROJECT_DIR"/Sources/iFileSpan/*.swift "$BUILD_DIR/DeviceCore.o" "$BUILD_DIR/DeviceBridge.o" \
    -o "$APP_DIR/Contents/MacOS/iFileSpan"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$PROJECT_DIR/AppIcon.icns" ]; then cp "$PROJECT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"; fi
if [ -f "$PROJECT_DIR/IconResources/Assets.car" ]; then cp "$PROJECT_DIR/IconResources/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"; fi
if [ -d "$PROJECT_DIR/Vendor/Frameworks" ]; then
    if [ "$ARCH" != arm64 ]; then echo "附带连接库为 arm64，请先准备目标架构的依赖。" >&2; exit 1; fi
    bash "$PROJECT_DIR/scripts/bundle-libraries.sh" "$APP_DIR"
    "$CLANG" "$PROJECT_DIR/scripts/library-check.c" "$BUILD_DIR/DeviceBridge.o" \
        -arch "$ARCH" -mmacosx-version-min=14.0 -isysroot "$SDK" -I "$BUILD_DIR/DeviceBridge" -o "$BUILD_DIR/library-check"
    "$BUILD_DIR/library-check" "$APP_DIR/Contents/Frameworks"
    "$CLANG" "$PROJECT_DIR/scripts/installation-bridge-test.c" \
        -arch "$ARCH" -mmacosx-version-min=14.0 -isysroot "$SDK" -I "$BUILD_DIR/DeviceBridge" -o "$BUILD_DIR/installation-bridge-test"
    "$BUILD_DIR/installation-bridge-test" "$APP_DIR/Contents/Frameworks"
fi
SIGNATURE_VERIFIED=0
for ATTEMPT in 1 2 3; do
    # File Provider can attach Finder metadata during both signing and inspection.
    xattr -cr "$APP_DIR"
    if codesign --force --sign - "$APP_DIR"; then
        xattr -cr "$APP_DIR"
        if codesign --verify --deep --strict "$APP_DIR"; then SIGNATURE_VERIFIED=1; break; fi
    fi
done
if [ "$SIGNATURE_VERIFIED" != 1 ]; then echo "安装包签名检查失败。" >&2; exit 1; fi
echo "已生成：$APP_DIR"

#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${DEVICEFILES_TEST_BUILD_DIR:-$PROJECT_DIR/.build/tests-manual}"
mkdir -p "$BUILD_DIR/tmp" "$BUILD_DIR/cache" "$BUILD_DIR/DeviceBridge"
export TMPDIR="$BUILD_DIR/tmp/"
export DEVICEFILES_TEST_TEMP="$BUILD_DIR/tmp"
DEVELOPER_PATH="$(xcode-select -p)"
SDK="$DEVELOPER_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
DEV_LIB="$DEVELOPER_PATH/Platforms/MacOSX.platform/Developer/usr/lib"
DEV_FRAMEWORKS="$DEVELOPER_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks"
SWIFTC="$DEVELOPER_PATH/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
CLANG="$DEVELOPER_PATH/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
ARCH="$(uname -m)"
cp "$PROJECT_DIR/Sources/DeviceBridge/include/DeviceBridge.h" "$BUILD_DIR/DeviceBridge/"
printf 'module DeviceBridge { header "DeviceBridge.h" export * }\n' > "$BUILD_DIR/DeviceBridge/module.modulemap"
"$CLANG" -c "$PROJECT_DIR/Sources/DeviceBridge/DeviceBridge.c" -arch "$ARCH" -mmacosx-version-min=14.0 \
    -isysroot "$SDK" -I "$BUILD_DIR/DeviceBridge" -o "$BUILD_DIR/DeviceBridge.o"
"$SWIFTC" -parse-as-library -emit-object -emit-module -whole-module-optimization -enable-testing \
    -module-name DeviceCore -module-cache-path "$BUILD_DIR/cache" -sdk "$SDK" \
    -I "$BUILD_DIR/DeviceBridge" -target "$ARCH-apple-macosx14.0" \
    "$PROJECT_DIR"/Sources/DeviceCore/*.swift -o "$BUILD_DIR/DeviceCore.o" \
    -emit-module-path "$BUILD_DIR/DeviceCore.swiftmodule"
"$SWIFTC" -parse-as-library -module-cache-path "$BUILD_DIR/cache" -sdk "$SDK" \
    -I "$BUILD_DIR" -I "$BUILD_DIR/DeviceBridge" -I "$DEV_LIB" -L "$DEV_LIB" \
    -F "$DEV_FRAMEWORKS" -framework XCTest \
    -Xlinker -rpath -Xlinker "$DEV_FRAMEWORKS" -Xlinker -rpath -Xlinker "$DEV_LIB" \
    -target "$ARCH-apple-macosx14.0" \
    "$PROJECT_DIR"/Tests/DeviceCoreTests/*.swift "$PROJECT_DIR/scripts/TestMain.swift" \
    "$BUILD_DIR/DeviceCore.o" "$BUILD_DIR/DeviceBridge.o" -o "$BUILD_DIR/TransferTests"
"$BUILD_DIR/TransferTests"

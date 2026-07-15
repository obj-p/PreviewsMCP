#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/.build-artifacts"
ARTIFACTS_DIR="$ROOT/Artifacts"
SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
DEVICE_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

rm -rf "$BUILD_DIR" "$ARTIFACTS_DIR"
mkdir -p "$BUILD_DIR/StaticBadge" "$BUILD_DIR/DynamicBadge.framework/Headers"
mkdir -p "$BUILD_DIR/DynamicBadge.framework/Modules" "$BUILD_DIR/DynamicBadge.framework/Resources"
mkdir -p "$ARTIFACTS_DIR"

xcrun clang \
    -target arm64-apple-ios17.0-simulator \
    -isysroot "$SIMULATOR_SDK" \
    -I "$ROOT/FrameworkSources/StaticBadge/include" \
    -c "$ROOT/FrameworkSources/StaticBadge/StaticBadge.c" \
    -o "$BUILD_DIR/StaticBadge/StaticBadge.o"
xcrun ar rcs \
    "$BUILD_DIR/StaticBadge/libStaticBadge.a" \
    "$BUILD_DIR/StaticBadge/StaticBadge.o"
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/StaticBadge/libStaticBadge.a" \
    -headers "$ROOT/FrameworkSources/StaticBadge/include" \
    -output "$ARTIFACTS_DIR/StaticBadge.xcframework"

cp "$ROOT/FrameworkSources/DynamicBadge/DynamicBadge.h" \
    "$BUILD_DIR/DynamicBadge.framework/Headers/DynamicBadge.h"
cp "$ROOT/FrameworkSources/DynamicBadge/module.modulemap" \
    "$BUILD_DIR/DynamicBadge.framework/Modules/module.modulemap"
cp "$ROOT/FrameworkSources/DynamicBadge/Info.plist" \
    "$BUILD_DIR/DynamicBadge.framework/Info.plist"
cp "$ROOT/FrameworkSources/DynamicBadge/fixture-payload.json" \
    "$BUILD_DIR/DynamicBadge.framework/Resources/fixture-payload.json"
xcrun clang \
    -target arm64-apple-ios17.0-simulator \
    -isysroot "$SIMULATOR_SDK" \
    -dynamiclib "$ROOT/FrameworkSources/DynamicBadge/DynamicBadge.c" \
    -I "$ROOT/FrameworkSources/DynamicBadge" \
    -install_name @rpath/DynamicBadge.framework/DynamicBadge \
    -o "$BUILD_DIR/DynamicBadge.framework/DynamicBadge"
codesign --force --sign - "$BUILD_DIR/DynamicBadge.framework"
xcodebuild -create-xcframework \
    -framework "$BUILD_DIR/DynamicBadge.framework" \
    -output "$ARTIFACTS_DIR/DynamicBadge.xcframework"

mkdir -p "$BUILD_DIR/BadSlice.framework/Headers" "$BUILD_DIR/BadSlice.framework/Modules"
cp "$ROOT/FrameworkSources/BadSlice/BadSlice.h" \
    "$BUILD_DIR/BadSlice.framework/Headers/BadSlice.h"
cp "$ROOT/FrameworkSources/BadSlice/module.modulemap" \
    "$BUILD_DIR/BadSlice.framework/Modules/module.modulemap"
cp "$ROOT/FrameworkSources/DynamicBadge/Info.plist" \
    "$BUILD_DIR/BadSlice.framework/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleExecutable BadSlice" \
    "$BUILD_DIR/BadSlice.framework/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :SupportedPlatform iPhoneOS" \
    "$BUILD_DIR/BadSlice.framework/Info.plist"
xcrun clang \
    -target arm64-apple-ios17.0 \
    -isysroot "$DEVICE_SDK" \
    -dynamiclib "$ROOT/FrameworkSources/BadSlice/BadSlice.c" \
    -I "$ROOT/FrameworkSources/BadSlice" \
    -install_name @rpath/BadSlice.framework/BadSlice \
    -o "$BUILD_DIR/BadSlice.framework/BadSlice"
codesign --force --sign - "$BUILD_DIR/BadSlice.framework"
xcodebuild -create-xcframework \
    -framework "$BUILD_DIR/BadSlice.framework" \
    -output "$ARTIFACTS_DIR/BadSlice.xcframework"

printf '%s\n' 'This is intentionally not a Mach-O dynamic library.' \
    > "$ARTIFACTS_DIR/Invalid.dylib"

for case_dir in static-only dynamic-only combined bad-slice; do
    rm -rf "$ROOT/$case_dir/Artifacts"
    mkdir -p "$ROOT/$case_dir/Artifacts"
done

cp -R "$ARTIFACTS_DIR/StaticBadge.xcframework" "$ROOT/static-only/Artifacts/"
cp -R "$ARTIFACTS_DIR/StaticBadge.xcframework" "$ROOT/combined/Artifacts/"
cp -R "$ARTIFACTS_DIR/DynamicBadge.xcframework" "$ROOT/dynamic-only/Artifacts/"
cp -R "$ARTIFACTS_DIR/DynamicBadge.xcframework" "$ROOT/combined/Artifacts/"
cp -R "$ARTIFACTS_DIR/BadSlice.xcframework" "$ROOT/bad-slice/Artifacts/"

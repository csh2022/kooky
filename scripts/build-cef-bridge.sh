#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CEF_DIR="${ROOT}/Vendor/CEF/current"
SRC_DIR="${ROOT}/Native/CEFBridge"
OUT_ROOT="${ROOT}/Vendor/CEFBridge/current"
BUILD_DIR="${ROOT}/.build/cef-bridge"
FRAMEWORK="${OUT_ROOT}/KookyCEFBridge.framework"
HELPER_NAMES=("Kooky Helper" "Kooky Helper (GPU)" "Kooky Helper (Plugin)" "Kooky Helper (Renderer)")

[ -d "$CEF_DIR" ] || {
    echo "missing CEF distribution. Run scripts/setup-cef.sh first." >&2
    exit 1
}

rm -rf "$BUILD_DIR" "$OUT_ROOT"
mkdir -p "$BUILD_DIR" "$FRAMEWORK/Headers" "$FRAMEWORK/Resources" "$OUT_ROOT"

COMMON_FLAGS=(
    -DOS_MAC=1
    -D__STDC_CONSTANT_MACROS
    -D__STDC_FORMAT_MACROS
    -D__STDC_LIMIT_MACROS
    -DWRAPPING_CEF_SHARED
    -I"$CEF_DIR"
    -I"$CEF_DIR/include"
    -fobjc-arc
)

COMMON_FRAMEWORKS=(
    -framework AppKit
    -framework Foundation
)

WRAPPER_SOURCES=(
    "$CEF_DIR/libcef_dll/wrapper/libcef_dll_dylib.cc"
    "$CEF_DIR/libcef_dll/wrapper/cef_scoped_library_loader_mac.mm"
)

echo "==> Building KookyCEFBridge.framework"
clang++ -std=c++17 -dynamiclib \
    "${COMMON_FLAGS[@]}" \
    -install_name "@rpath/KookyCEFBridge.framework/KookyCEFBridge" \
    "${COMMON_FRAMEWORKS[@]}" \
    "${WRAPPER_SOURCES[@]}" \
    "$SRC_DIR/KookyCEFBridge.mm" \
    -o "$FRAMEWORK/KookyCEFBridge"
cp "$SRC_DIR/KookyCEFBridge.h" "$FRAMEWORK/Headers/"
cat > "$FRAMEWORK/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.iamcorey.kooky.cefbridge</string>
    <key>CFBundleName</key><string>KookyCEFBridge</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleExecutable</key><string>KookyCEFBridge</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST

echo "==> Building CEF helper apps"
for helper in "${HELPER_NAMES[@]}"; do
    app="$OUT_ROOT/${helper}.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    clang++ -std=c++17 \
        "${COMMON_FLAGS[@]}" \
        "$SRC_DIR/KookyCEFHelper.c" \
        "${WRAPPER_SOURCES[@]}" \
        "${COMMON_FRAMEWORKS[@]}" \
        -o "$app/Contents/MacOS/$helper"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.iamcorey.kooky.${helper// /-}</string>
    <key>CFBundleName</key><string>${helper}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>${helper}</string>
    <key>LSBackgroundOnly</key><true/>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
done

echo "Prepared CEF bridge at $OUT_ROOT"

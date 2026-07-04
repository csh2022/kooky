#!/usr/bin/env bash
# Build kooky as a real macOS .app bundle (no Xcode project required).
#
# What this does:
#   1. swift build -c release
#   2. Assemble dist/Kooky.app/Contents/{MacOS,Resources,Info.plist,PkgInfo}
#   3. Copy Kooky binary + the SPM resource bundle into MacOS/
#      (Bundle.module looks next to the executable, which is why fonts +
#      icons live alongside the binary, not under Resources/)
#   4. Generate Info.plist with CFBundleShortVersionString sourced from
#      Sources/KookyKit/App/AppInfo.swift's displayVersion — single source
#      of truth, no manual sync
#   5. Adhoc codesign so Gatekeeper doesn't kill it on first launch
#
# Output: dist/Kooky.app — open it directly or drop into /Applications.
# This is local-distribution-only. Codesigning + notarization for public
# release is a separate step (requires Apple Developer ID).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Pull displayVersion from AppInfo.swift so About + Info.plist stay in sync.
VERSION="$(grep -E 'static let displayVersion' Sources/KookyKit/App/AppInfo.swift \
    | sed -E 's/.*= "([^"]+)".*/\1/')"
if [ -z "$VERSION" ]; then
    echo "build-app.sh: failed to extract displayVersion from AppInfo.swift" >&2
    exit 1
fi

BUNDLE_ID="com.iamcorey.kooky"
APP_NAME="Kooky"
APP="dist/${APP_NAME}.app"

echo "==> Building release config"
swift build -c release --product Kooky

echo "==> Verifying build artifacts"
for f in .build/release/Kooky; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
[ -d ".build/release/Kooky_KookyKit.bundle" ] || {
    echo "missing SPM resource bundle: .build/release/Kooky_KookyKit.bundle" >&2
    exit 1
}

echo "==> Assembling ${APP} (v${VERSION})"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
mkdir -p "${APP}/Contents/Frameworks"

cp .build/release/Kooky "${APP}/Contents/MacOS/${APP_NAME}"
# Bundle.module's first lookup candidate is `Bundle.main.resourceURL`
# (= Contents/Resources/), so the resource bundle has to live there or
# the running .app will silently fall back to .build/release/ on disk.
cp -R .build/release/Kooky_KookyKit.bundle "${APP}/Contents/Resources/"

CEF_VENDOR_DIR="${ROOT}/Vendor/CEF/current"
CEF_BRIDGE_DIR="${ROOT}/Vendor/CEFBridge/current"
if [ -d "$CEF_VENDOR_DIR" ]; then
    echo "==> Bundling CEF from ${CEF_VENDOR_DIR}"
    [ -d "${CEF_VENDOR_DIR}/Chromium Embedded Framework.framework" ] || {
        echo "missing CEF framework: ${CEF_VENDOR_DIR}/Chromium Embedded Framework.framework" >&2
        exit 1
    }
    CEF_FRAMEWORK_DEST="${APP}/Contents/Frameworks/Chromium Embedded Framework.framework"
    mkdir -p "${CEF_FRAMEWORK_DEST}/Versions/A" "${CEF_FRAMEWORK_DEST}/Versions"
    cp -R "${CEF_VENDOR_DIR}/Chromium Embedded Framework.framework/." "${CEF_FRAMEWORK_DEST}/Versions/A/"
    ln -sfn "Versions/A/Chromium Embedded Framework" "${CEF_FRAMEWORK_DEST}/Chromium Embedded Framework"
    ln -sfn "Versions/A/Libraries" "${CEF_FRAMEWORK_DEST}/Libraries"
    ln -sfn "Versions/A/Resources" "${CEF_FRAMEWORK_DEST}/Resources"
    ln -sfn "A" "${CEF_FRAMEWORK_DEST}/Versions/Current"
    CEF_HELPERS=()
    shopt -s nullglob
    CEF_HELPERS=(
        "${CEF_VENDOR_DIR}"/Kooky\ Helper*.app
        "${CEF_BRIDGE_DIR}"/Kooky\ Helper*.app
    )
    shopt -u nullglob
    if [ "${#CEF_HELPERS[@]}" -eq 0 ]; then
        echo "warning: CEF framework present but no Kooky Helper apps found; Chromium engine will not launch yet" >&2
    else
        for helper in "${CEF_HELPERS[@]}"; do
            cp -R "$helper" "${APP}/Contents/Frameworks/"
        done
    fi
    if [ -d "${CEF_BRIDGE_DIR}/KookyCEFBridge.framework" ]; then
        echo "==> Bundling KookyCEFBridge from ${CEF_BRIDGE_DIR}"
        cp -R "${CEF_BRIDGE_DIR}/KookyCEFBridge.framework" "${APP}/Contents/Frameworks/"
    else
        echo "warning: CEF framework present but KookyCEFBridge.framework is missing; Chromium engine will not launch yet" >&2
    fi
fi

# App icon — generated from branding/AppIcon.png if present. macOS reads
# .icns from CFBundleIconFile in Info.plist; we synthesize the multi-size
# .iconset via sips, then iconutil packs it. Without a source PNG we ship
# without an icon and the OS falls back to the generic blank-document.
# Pick the largest available source from branding/icons/ — asset catalog
# format names the 1024px slot `icon-512@2x.png`. Fall back to a flat
# `icon-1024.png` (older convention) then to legacy `branding/AppIcon.png`.
for cand in branding/icons/icon-512@2x.png branding/icons/icon-1024.png branding/AppIcon.png; do
    if [ -f "$cand" ]; then
        ICON_SOURCE="$cand"
        break
    fi
done
if [ -f "$ICON_SOURCE" ]; then
    echo "==> Building AppIcon.icns from ${ICON_SOURCE}"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    # Apple's required sizes for an .icns: 16/32/128/256/512 in @1x and @2x.
    # sips resamples cleanly enough for a flat brand mark; for fine detail
    # design, hand-export from Figma/Sketch is preferred.
    for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" \
                "32:icon_32x32.png" "64:icon_32x32@2x.png" \
                "128:icon_128x128.png" "256:icon_128x128@2x.png" \
                "256:icon_256x256.png" "512:icon_256x256@2x.png" \
                "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
        size="${spec%%:*}"
        name="${spec##*:}"
        sips -z "$size" "$size" "$ICON_SOURCE" --out "${ICONSET}/${name}" >/dev/null
    done
    iconutil -c icns -o "${APP}/Contents/Resources/AppIcon.icns" "$ICONSET"
    rm -rf "$(dirname "$ICONSET")"
    APPLE_ICON_PLIST_KEYS=$(cat <<'KEYS'
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
KEYS
    )
else
    APPLE_ICON_PLIST_KEYS=""
fi

# SPM ships the resource bundle as a flat directory, but its `.bundle` suffix
# triggers codesign's bundle validator → "bundle format invalid". Promote it
# to the canonical macOS bundle layout (Contents/Info.plist +
# Contents/Resources/*) so codesign accepts it. Bundle.module still resolves
# fonts/icons via its standard resourcePath lookup.
RES_BUNDLE="${APP}/Contents/Resources/Kooky_KookyKit.bundle"
mkdir -p "${RES_BUNDLE}/Contents/Resources"
mv "${RES_BUNDLE}"/*.ttf "${RES_BUNDLE}"/*.png "${RES_BUNDLE}/Contents/Resources/" 2>/dev/null || true
cat > "${RES_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}.resources</string>
    <key>CFBundleName</key>
    <string>Kooky_KookyKit</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
</dict>
</plist>
PLIST

# PkgInfo: 4-byte CFBundlePackageType + 4-byte CFBundleSignature.
# Modern macOS doesn't require it but Finder still uses it for some legacy
# checks; harmless 8 bytes.
printf 'APPL????' > "${APP}/Contents/PkgInfo"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>kooky</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Kooky uses the embedded Chromium browser engine, which may inspect Bluetooth device state for web platform compatibility.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
${APPLE_ICON_PLIST_KEYS}
</dict>
</plist>
PLIST

echo "==> Adhoc codesign (skips Gatekeeper kill on first launch)"
# Adhoc signature ('-') is enough for personal-machine launches without a
# Developer ID. Public distribution still needs a real cert + notarytool.
# Sign inside-out: inner resource bundle first, then binaries, then the
# .app — each layer wants its descendants already signed before signing
# itself.
codesign --force --sign - "${APP}/Contents/Resources/Kooky_KookyKit.bundle"
if [ -d "${APP}/Contents/Frameworks/Chromium Embedded Framework.framework" ]; then
    BUNDLED_CEF_HELPERS=()
    shopt -s nullglob
    BUNDLED_CEF_HELPERS=("${APP}/Contents/Frameworks"/*.app)
    shopt -u nullglob
    if [ "${#BUNDLED_CEF_HELPERS[@]}" -gt 0 ]; then
        for helper in "${BUNDLED_CEF_HELPERS[@]}"; do
            codesign --force --deep --sign - "$helper"
        done
    fi
    if [ -d "${APP}/Contents/Frameworks/KookyCEFBridge.framework" ]; then
        codesign --force --deep --sign - "${APP}/Contents/Frameworks/KookyCEFBridge.framework"
    fi
    CEF_FRAMEWORK="${APP}/Contents/Frameworks/Chromium Embedded Framework.framework"
    if ! codesign --force --deep --sign - "${CEF_FRAMEWORK}"; then
        if codesign -dv "${CEF_FRAMEWORK}/Versions/A/Chromium Embedded Framework" >/dev/null 2>&1; then
            echo "warning: keeping existing valid CEF signature after codesign retry failed" >&2
        else
            exit 1
        fi
    fi
fi
codesign --force --sign - "${APP}/Contents/MacOS/${APP_NAME}"
codesign --force --sign - "${APP}" 2>&1 | tail -3

echo ""
echo "✓ Built ${APP} (v${VERSION})"
echo "  open ${APP}              # launch"
echo "  cp -R ${APP} /Applications  # install"

#!/usr/bin/env bash
# Build kooky as a real macOS .app bundle (no Xcode project required).
#
# What this does:
#   1. swift build -c release
#   2. Assemble dist/Kooky.app/Contents/{MacOS,Resources,Info.plist,PkgInfo}
#   3. Copy Kooky + KookyHook binaries + the SPM resource bundle into MacOS/
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
swift build -c release

echo "==> Verifying build artifacts"
for f in .build/release/Kooky .build/release/KookyHook; do
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

cp .build/release/Kooky "${APP}/Contents/MacOS/${APP_NAME}"
cp .build/release/KookyHook "${APP}/Contents/MacOS/KookyHook"
# Bundle.module's first lookup candidate is `Bundle.main.resourceURL`
# (= Contents/Resources/), so the resource bundle has to live there or
# the running .app will silently fall back to .build/release/ on disk.
cp -R .build/release/Kooky_KookyKit.bundle "${APP}/Contents/Resources/"

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
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
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
codesign --force --sign - "${APP}/Contents/MacOS/${APP_NAME}"
codesign --force --sign - "${APP}/Contents/MacOS/KookyHook"
codesign --force --sign - "${APP}" 2>&1 | tail -3

echo ""
echo "✓ Built ${APP} (v${VERSION})"
echo "  open ${APP}              # launch"
echo "  cp -R ${APP} /Applications  # install"

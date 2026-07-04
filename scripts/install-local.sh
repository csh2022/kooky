#!/usr/bin/env bash
# Build and install Kooky on this Mac. This is the local developer install
# path; public distribution still goes through build-dmg.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Kooky"
BUILT_APP="dist/${APP_NAME}.app"
INSTALL_APP="/Applications/${APP_NAME}.app"
SUPPORT_DIR="${HOME}/Library/Application Support/kooky"
SUPPORT_HOOK="${SUPPORT_DIR}/bin/KookyHook"

echo "==> Building ${APP_NAME}.app"
"${ROOT}/scripts/build-app.sh"

[ -d "$BUILT_APP" ] || {
    echo "install-local.sh: missing ${BUILT_APP}" >&2
    exit 1
}

echo "==> Overlay installing ${INSTALL_APP}"
ditto "$BUILT_APP" "$INSTALL_APP"

echo "==> Clearing stale legacy copied helper"
rm -f "$SUPPORT_HOOK"

echo ""
echo "✓ Installed ${INSTALL_APP}"
echo "  Running ${APP_NAME} instances were not stopped."
echo "  Restart ${APP_NAME} to use the newly installed build."
echo "  Hook calls now use ${INSTALL_APP}/Contents/MacOS/${APP_NAME}; no separate KookyHook binary is installed."

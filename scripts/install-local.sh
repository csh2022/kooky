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

echo "==> Stopping running ${APP_NAME} instances"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "==> Force stopping stubborn ${APP_NAME} instances"
    pkill -9 -x "$APP_NAME" 2>/dev/null || true
    sleep 1
fi

echo "==> Installing ${INSTALL_APP}"
rm -rf "$INSTALL_APP"
cp -R "$BUILT_APP" "$INSTALL_APP"

echo "==> Clearing stale legacy copied helper"
rm -f "$SUPPORT_HOOK"

echo "==> Launching installed ${APP_NAME}"
open "$INSTALL_APP"

echo ""
echo "✓ Installed ${INSTALL_APP}"
echo "  Hook calls now use ${INSTALL_APP}/Contents/MacOS/${APP_NAME}; no separate KookyHook binary is installed."

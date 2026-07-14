#!/usr/bin/env bash
# Verify that an assembled Kooky.app contains every runtime component required
# by the Chromium browser engine.

set -euo pipefail

APP="${1:-dist/Kooky.app}"
FRAMEWORKS="${APP}/Contents/Frameworks"
HELPER_NAMES=(
    "Kooky Helper"
    "Kooky Helper (GPU)"
    "Kooky Helper (Plugin)"
    "Kooky Helper (Renderer)"
)

missing=()

[ -d "${FRAMEWORKS}/Chromium Embedded Framework.framework" ] || \
    missing+=("Chromium Embedded Framework.framework")
[ -x "${FRAMEWORKS}/Chromium Embedded Framework.framework/Chromium Embedded Framework" ] || \
    missing+=("Chromium Embedded Framework executable")
[ -d "${FRAMEWORKS}/KookyCEFBridge.framework" ] || \
    missing+=("KookyCEFBridge.framework")
[ -x "${FRAMEWORKS}/KookyCEFBridge.framework/KookyCEFBridge" ] || \
    missing+=("KookyCEFBridge executable")

for helper_name in "${HELPER_NAMES[@]}"; do
    [ -d "${FRAMEWORKS}/${helper_name}.app" ] || \
        missing+=("${helper_name}.app")
    [ -x "${FRAMEWORKS}/${helper_name}.app/Contents/MacOS/${helper_name}" ] || \
        missing+=("${helper_name} executable")
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "verify-cef-app.sh: ${APP} is missing Chromium runtime components:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
fi

echo "✓ Verified complete Chromium runtime in ${APP}"

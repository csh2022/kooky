#!/usr/bin/env bash
#
# Downloads and prepares a CEF macOS binary distribution for Kooky's future
# Chromium-backed browser engine. The downloaded payload is intentionally kept
# under Vendor/CEF, which is ignored by git.

set -euo pipefail

CEF_VERSION_DEFAULT="144.0.29+g0b1a012+chromium-144.0.7559.256"
CEF_SHA1_MACOSARM64_DEFAULT="96dfcb1c89413cd8c740d8abc424e1134c4ae20b"
CEF_SHA1_MACOSX64_DEFAULT="be87a2104eecbcc2ac30f7ded349e3e9e913efd9"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT}/Vendor/CEF"
CURRENT_DIR="${VENDOR_DIR}/current"
DOWNLOAD_DIR="${VENDOR_DIR}/downloads"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kooky-cef.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

detect_platform() {
    case "$(uname -m)" in
        arm64)
            echo "macosarm64"
            ;;
        x86_64)
            echo "macosx64"
            ;;
        *)
            echo "unsupported"
            ;;
    esac
}

CEF_VERSION="${KOOKY_CEF_VERSION:-$CEF_VERSION_DEFAULT}"
CEF_PLATFORM="${KOOKY_CEF_PLATFORM:-$(detect_platform)}"
case "$CEF_PLATFORM" in
    macosarm64)
        CEF_SHA1_DEFAULT="$CEF_SHA1_MACOSARM64_DEFAULT"
        ;;
    macosx64)
        CEF_SHA1_DEFAULT="$CEF_SHA1_MACOSX64_DEFAULT"
        ;;
    *)
        CEF_SHA1_DEFAULT=""
        ;;
esac
CEF_SHA1="${KOOKY_CEF_SHA1:-$CEF_SHA1_DEFAULT}"
CEF_ARCHIVE="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}.tar.bz2"
CEF_URL="${KOOKY_CEF_URL:-https://cef-builds.spotifycdn.com/${CEF_ARCHIVE}}"

ARCHIVE_PATH="${DOWNLOAD_DIR}/${CEF_ARCHIVE}"
EXTRACT_DIR="${TMP_DIR}/extract"

if [[ "$CEF_PLATFORM" == "unsupported" ]]; then
    echo "Unsupported host architecture for CEF: $(uname -m)" >&2
    echo "Set KOOKY_CEF_PLATFORM explicitly if you have a compatible CEF build." >&2
    exit 1
fi

mkdir -p "$VENDOR_DIR" "$DOWNLOAD_DIR"

if [[ -f "${CURRENT_DIR}/.cef-version" && "$(cat "${CURRENT_DIR}/.cef-version")" == "${CEF_VERSION} ${CEF_PLATFORM}" ]]; then
    echo "CEF already prepared at ${CURRENT_DIR} (${CEF_VERSION} ${CEF_PLATFORM}). Skipping."
    exit 0
fi

echo "Downloading CEF ${CEF_VERSION} (${CEF_PLATFORM})..."
curl --fail --show-error --location \
    --continue-at - \
    --connect-timeout 10 \
    --max-time 900 \
    --retry 5 \
    --retry-delay 5 \
    --retry-all-errors \
    -o "$ARCHIVE_PATH" \
    "$CEF_URL"

ACTUAL_SHA1="$(shasum -a 1 "$ARCHIVE_PATH" | awk '{print $1}')"
if [[ -n "$CEF_SHA1" && "$ACTUAL_SHA1" != "$CEF_SHA1" ]]; then
    echo "CEF checksum mismatch!" >&2
    echo "  expected: $CEF_SHA1" >&2
    echo "  actual:   $ACTUAL_SHA1" >&2
    exit 1
fi

echo "Verified. Extracting..."
mkdir -p "$EXTRACT_DIR"
tar --no-same-owner -xjf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

DIST_DIR=""
for dir in "${EXTRACT_DIR}"/cef_binary_*; do
    if [[ -d "$dir" ]]; then
        DIST_DIR="$dir"
        break
    fi
done
if [[ -z "$DIST_DIR" ]]; then
    echo "Archive did not contain a cef_binary_* directory." >&2
    exit 1
fi

FRAMEWORK_SRC="$(find "$DIST_DIR" -path '*/Release/Chromium Embedded Framework.framework' -type d -print -quit)"
if [[ -z "$FRAMEWORK_SRC" ]]; then
    echo "CEF distribution did not contain Release/Chromium Embedded Framework.framework." >&2
    exit 1
fi

rm -rf "${CURRENT_DIR}.next"
mkdir -p "${CURRENT_DIR}.next"
cp -R "$FRAMEWORK_SRC" "${CURRENT_DIR}.next/"

printf '%s %s\n' "$CEF_VERSION" "$CEF_PLATFORM" > "${CURRENT_DIR}.next/.cef-version"
rm -rf "$CURRENT_DIR"
mv "${CURRENT_DIR}.next" "$CURRENT_DIR"

echo "Prepared CEF at ${CURRENT_DIR}"
echo "Note: Kooky Helper*.app bundles are produced by the app build in a later stage, not by this CEF download script."
for item in "${CURRENT_DIR}"/*; do
    [[ -e "$item" ]] || continue
    echo "$item"
done

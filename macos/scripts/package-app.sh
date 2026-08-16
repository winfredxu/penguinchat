#!/usr/bin/env bash
# Builds PenguinChat.app from the SwiftPM executable.
#
# A bundle (not `swift run`) is required for the real macOS surfaces: without a
# bundle identifier UNUserNotificationCenter is unavailable and the Keychain
# item has no stable owner.
#
#   ./scripts/package-app.sh                # Release, ad-hoc signed
#   CONFIGURATION=debug ./scripts/package-app.sh
#   SIGN_IDENTITY="Developer ID Application: … (TEAMID)" ./scripts/package-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" is ad-hoc; fine for local runs.
APP_NAME="PenguinChat"
BUILD_ROOT="PenguinChatMac"
OUTPUT_DIR="${OUTPUT_DIR:-build}"
APP="${OUTPUT_DIR}/${APP_NAME}.app"

echo "==> swift build -c ${CONFIGURATION}"
swift build --package-path "${BUILD_ROOT}" -c "${CONFIGURATION}" --product PenguinChatMac
BINARY="$(swift build --package-path "${BUILD_ROOT}" -c "${CONFIGURATION}" --show-bin-path)/PenguinChatMac"
test -x "${BINARY}" || { echo "missing built binary at ${BINARY}" >&2; exit 1; }

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BINARY}" "${APP}/Contents/MacOS/PenguinChatMac"
cp packaging/Info.plist "${APP}/Contents/Info.plist"
cp packaging/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Ad-hoc signatures cannot carry a keychain-access-group entitlement (there is
# no Team ID to substitute into $(AppIdentifierPrefix)), and an unsandboxed app
# does not need one. Only a Developer ID build gets the entitlements file.
echo "==> codesign (identity: ${SIGN_IDENTITY})"
if [ "${SIGN_IDENTITY}" = "-" ]; then
  codesign --force --sign - --timestamp=none "${APP}"
else
  codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp \
    --entitlements packaging/PenguinChatMac.entitlements "${APP}"
fi

codesign --verify --deep --strict "${APP}"
echo "==> ${APP} ready"
echo "    open ${APP}"
echo "    PENGUINCHAT_API_URL=http://127.0.0.1:3100 open -a \"\$PWD/${APP}\""

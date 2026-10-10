#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Prefer currently connected coredevice UUID
DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ {print $(NF-3); exit}')"
# Fallback: 3rd column often is Identifier
if [[ -z "${DEVICE:-}" || "$DEVICE" == "Identifier" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ {print $3; exit}')"
fi
if [[ -z "${DEVICE:-}" ]]; then
  echo "No connected iPhone found. Unlock it, trust this Mac, keep cable plugged."
  exit 1
fi
echo "Device: $DEVICE"

DERIVED="$ROOT/build/cli"
APP="$DERIVED/Build/Products/Debug-iphoneos/Juggle Dude.app"

echo "Building…"
xcodebuild \
  -project kicklab.xcodeproj \
  -scheme JuggleDude \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build

echo "Installing… (unlock phone if this hangs)"
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "Launching…"
xcrun devicectl device process launch --device "$DEVICE" com.juggledude
echo "Done."

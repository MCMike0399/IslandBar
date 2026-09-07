#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)"
APP="$ROOT/dist/IslandBar.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"

cp "$BIN/IslandBar" "$CONTENTS/MacOS/IslandBar"
cp "$BIN/libMediaRemoteAdapter.dylib" "$CONTENTS/Frameworks/"

BUNDLE="$(find "$ROOT/.build" -type d -name 'MediaRemoteAdapter_MediaRemoteAdapter.bundle' | head -n 1)"
if [[ -z "$BUNDLE" ]]; then
  echo "error: MediaRemoteAdapter_MediaRemoteAdapter.bundle not found under .build" >&2
  exit 1
fi
cp -R "$BUNDLE" "$CONTENTS/Resources/"

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if ! otool -l "$CONTENTS/MacOS/IslandBar" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$CONTENTS/MacOS/IslandBar"
fi

codesign --force --deep --sign - --options runtime --entitlements "$ROOT/Resources/IslandBar.entitlements" "$APP"
codesign -dv --verbose=2 "$APP"
plutil -lint "$ROOT/Resources/Info.plist"
otool -L "$CONTENTS/MacOS/IslandBar"

if [[ "${1:-}" == "--run" ]]; then
  # SIGTERM is handled as a clean quit, which also disarms the relaunch watchdog.
  # Wait for the old instance to leave before opening the new one.
  if pkill -x IslandBar; then
    for _ in $(seq 1 25); do
      pgrep -x IslandBar >/dev/null || break
      sleep 0.2
    done
    pkill -9 -x IslandBar || true
  fi
  if [[ "${ISLANDBAR_DEBUG:-}" == "1" ]]; then
    open --env ISLANDBAR_DEBUG=1 "$APP"
  else
    open "$APP"
  fi
fi

#!/bin/bash
# Launch a packaged IslandBar.app the way a user's Mac would see it, and require it to
# stay up.
#
#   Scripts/launch-smoke.sh [path/to/IslandBar.app]     (default dist/IslandBar.app)
#
# "The way a user's Mac would see it" means without this checkout's .build directory.
# SwiftPM bakes the absolute path of that directory into the binary as a fallback for
# finding resource bundles, so on the machine that built it a mispackaged app still finds
# everything — and on every other Mac it traps at launch. That is exactly how v0.5.0
# shipped: built on a GitHub runner, it crashed on launch everywhere else, and a crashed
# app cannot update itself out of it (PITFALLS.md, "A build only proves itself away from
# its .build"). So .build is moved aside for the few seconds the app runs.
#
# Run by Scripts/release.sh before anything is committed or published, and by
# `Scripts/harness check packaging`. Exits 0 when the app is still running after
# SMOKE_SECONDS (default 8) and quits cleanly on SIGTERM.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/IslandBar.app}"
APP="$(cd "$APP" && pwd)"
SECONDS_UP="${SMOKE_SECONDS:-8}"
BIN="$APP/Contents/MacOS/IslandBar"
[[ -x "$BIN" ]] || { echo "launch-smoke: no executable at $BIN" >&2; exit 2; }

# A second instance hands over to the first and exits at once, which would read as a
# crash. Quit any running copy (SIGTERM is a clean quit) and bring it back afterwards.
previous=""
if pid="$(pgrep -x IslandBar | sed -n 1p)" && [[ -n "$pid" ]]; then
  previous="$(ps -o comm= -p "$pid" | sed 's#/Contents/MacOS/IslandBar$##')"
  pkill -x IslandBar || true
  for _ in $(seq 1 25); do pgrep -x IslandBar >/dev/null || break; sleep 0.2; done
fi

hidden=""
smoke_pid=""
cleanup() {
  [[ -n "$smoke_pid" ]] && kill -TERM "$smoke_pid" 2>/dev/null || true
  if [[ -n "$hidden" && -d "$hidden" && ! -e "$ROOT/.build" ]]; then
    mv "$hidden" "$ROOT/.build"
  fi
  if [[ -n "$previous" && -d "$previous" ]]; then
    open "$previous" || true
  fi
}
trap cleanup EXIT

if [[ -d "$ROOT/.build" ]]; then
  hidden="$ROOT/.build.launch-smoke"
  rm -rf "$hidden"
  mv "$ROOT/.build" "$hidden"
fi

log="$(mktemp -t islandbar-smoke)"
# Straight from the shell is fine here: this checks that the app starts, not that it may
# capture audio, so TCC attribution does not matter. No watchdog: a crash must stay a crash.
ISLANDBAR_NO_WATCHDOG=1 "$BIN" >"$log" 2>&1 &
smoke_pid=$!
sleep "$SECONDS_UP"

if ! kill -0 "$smoke_pid" 2>/dev/null; then
  wait "$smoke_pid" && status=0 || status=$?
  smoke_pid=""
  echo "launch-smoke: FAIL — $APP exited within ${SECONDS_UP}s (status $status) with .build out of the way" >&2
  sed 's/^/  /' "$log" | tail -n 20 >&2
  crash="$(ls -t "$HOME/Library/Logs/DiagnosticReports"/IslandBar-*.ips 2>/dev/null | sed -n 1p || true)"
  [[ -n "$crash" ]] && echo "  newest crash report: $crash" >&2
  exit 1
fi

kill -TERM "$smoke_pid"
for _ in $(seq 1 25); do kill -0 "$smoke_pid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$smoke_pid" 2>/dev/null; then
  kill -9 "$smoke_pid" 2>/dev/null || true
  smoke_pid=""
  echo "launch-smoke: FAIL — $APP did not quit on SIGTERM" >&2
  exit 1
fi
smoke_pid=""
echo "launch-smoke: PASS — $APP stayed up ${SECONDS_UP}s away from .build and quit cleanly"

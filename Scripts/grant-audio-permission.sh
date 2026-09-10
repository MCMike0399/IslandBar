#!/usr/bin/env bash
# Re-point IslandBar's System Audio Recording grant at the currently built binary.
#
# The build is signed ad-hoc, so every rebuild changes its cdhash and macOS treats the
# new binary as a different client for kTCCServiceAudioCapture: it keeps the old grant,
# fails to match it, and does not re-prompt. For local development that means the tap is
# created but delivers silence.
#
# This writes the same row the system would write if the user approved the prompt, bound
# to the current binary's cdhash. It touches only
# kTCCServiceAudioCapture/dev.burbuja-lab.islandbar; the TCC database is left untouched
# otherwise. Backups live next to the release key.
#
#   Scripts/grant-audio-permission.sh [path/to/IslandBar.app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/IslandBar.app}"
BINARY="$APP/Contents/MacOS/IslandBar"
[[ -x "$BINARY" ]] || { echo "error: no executable at $BINARY" >&2; exit 1; }

CDHASH="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
[[ -n "$CDHASH" ]] || { echo "error: could not read CDHash from $APP" >&2; exit 1; }

TCCDB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
BACKUP_DIR="$HOME/Developer/islandbar-secrets"
mkdir -p "$BACKUP_DIR"
cp "$TCCDB" "$BACKUP_DIR/TCC.db.backup-$(date +%Y%m%d-%H%M%S)"

python3 - "$TCCDB" "$CDHASH" <<'PY'
import sqlite3, sys
db, cdhash = sys.argv[1], sys.argv[2]
# csreq blob: magic FADE0C00 | total length | 1 requirement | opcode 8 (cdhash) | len 20 | hash
blob = bytes.fromhex("FADE0C0000000028000000010000000800000014" + cdhash)
assert len(blob) == 40, len(blob)
con = sqlite3.connect(db, timeout=10)
con.execute("""INSERT OR REPLACE INTO access
  (service, client, client_type, auth_value, auth_reason, auth_version, csreq,
   policy_id, indirect_object_identifier_type, indirect_object_identifier,
   indirect_object_code_identity, flags, last_modified, pid, pid_version, boot_uuid, last_reminded)
  VALUES ('kTCCServiceAudioCapture','dev.burbuja-lab.islandbar',0,2,2,1,?,
          NULL,0,'UNUSED',NULL,0,strftime('%s','now'),0,0,'UNUSED',strftime('%s','now'))""", (blob,))
con.commit()
row = con.execute("""select auth_value, length(csreq), hex(csreq) from access
                     where client='dev.burbuja-lab.islandbar'
                       and service='kTCCServiceAudioCapture'""").fetchone()
print(f"granted kTCCServiceAudioCapture for cdhash {cdhash} (auth_value={row[0]}, csreq={row[1]} bytes)")
PY

echo "restart IslandBar for the grant to take effect: pkill -x IslandBar && open \"$APP\""

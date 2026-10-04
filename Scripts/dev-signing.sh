#!/bin/bash
# A stable signing identity for *local* builds, so a TCC grant survives rebuilds.
#
#   Scripts/dev-signing.sh setup        create the identity (once per Mac)
#   Scripts/dev-signing.sh status       is it there, and what requirement does it give
#   Scripts/dev-signing.sh available    exit 0 if build.sh can use it
#   Scripts/dev-signing.sh sign <app>   sign a bundle with it (build.sh calls this)
#   Scripts/dev-signing.sh remove       delete the identity and its keychain
#
# Why: an ad-hoc signature's designated requirement is its cdhash, which changes on every
# build, so macOS asks for System Audio Recording again after every rebuild — and on a Mac
# that lives with its lid closed nobody is there to click Allow, so an agent can never get
# a working tap. Signed with this identity the requirement becomes
#   identifier "dev.burbuja-lab.islandbar" and certificate leaf = H"…"
# which stays the same from build to build: grant it once and it holds.
#
# The identity is a self-signed certificate in its own keychain
# (~/Library/Keychains/islandbar-dev.keychain-db) whose password is a random string in
# ~/.config/islandbar/dev-keychain.pass, so signing never needs the login password and
# never raises a keychain prompt. It is untrusted, which codesign does not mind as long as
# it is named by its SHA-1 and its keychain is on the search list — so `sign` puts the
# keychain on the list for the one codesign call and restores the list afterwards. It is
# not left there: after a reboot it would come back locked, and other apps would start
# asking for its password.
#
# Releases are never signed with it: Scripts/release.sh builds with ISLANDBAR_ADHOC=1, and
# CI has no such keychain. See PITFALLS.md ("A TCC grant is bound to the exact code
# signature").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN="$HOME/Library/Keychains/islandbar-dev.keychain-db"
PASSFILE="$HOME/.config/islandbar/dev-keychain.pass"
NAME="IslandBar Local Development"
ENTITLEMENTS="$ROOT/Resources/IslandBar.entitlements"

identity_hash() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v name="\"$NAME\"" 'index($0, name) { print $2; exit }'
}

unlock() {
  security unlock-keychain -p "$(cat "$PASSFILE")" "$KEYCHAIN"
}

available() { [[ -f "$KEYCHAIN" && -r "$PASSFILE" ]] && [[ -n "$(identity_hash)" ]]; }

# The user search list, one path per line, exactly as security prints it minus quotes.
search_list() { security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'; }

setup() {
  if available; then
    echo "already set up: $(identity_hash) in $KEYCHAIN"
    return
  fi
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$(dirname "$PASSFILE")"
  ( umask 077; /usr/bin/openssl rand -hex 24 > "$PASSFILE" )
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  # /usr/bin/openssl is LibreSSL. A Homebrew OpenSSL 3 writes a PKCS#12 that `security
  # import` rejects ("MAC verification failed") unless given -legacy.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
    -passout pass:transfer -out "$tmp/id.p12"
  [[ -f "$KEYCHAIN" ]] && security delete-keychain "$KEYCHAIN"
  security create-keychain -p "$(cat "$PASSFILE")" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"   # no auto-lock timeout
  unlock
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P transfer -T /usr/bin/codesign >/dev/null
  # Lets codesign use the key without a prompt; needs this keychain's password, not the
  # login one, which is the point of a keychain of its own.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$PASSFILE")" "$KEYCHAIN" >/dev/null
  # create-keychain adds itself to the search list; take it back off (see the header).
  local others=()
  while IFS= read -r k; do [[ "$k" == "$KEYCHAIN" ]] || others+=("$k"); done < <(search_list)
  [[ ${#others[@]} -gt 0 ]] && security list-keychains -d user -s "${others[@]}"
  echo "created $(identity_hash) \"$NAME\" in $KEYCHAIN"
  echo "next: build, launch, and grant System Audio Recording once — it then survives rebuilds"
}

# Global, not local: the trap that restores it can fire after `sign` has returned.
SAVED_LIST=()
restore_list() {
  if [[ ${#SAVED_LIST[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${SAVED_LIST[@]}"
    SAVED_LIST=()
  fi
}

sign() {
  local app="$1"
  available || { echo "error: no development identity (Scripts/dev-signing.sh setup)" >&2; exit 3; }
  unlock
  while IFS= read -r k; do [[ "$k" == "$KEYCHAIN" ]] || SAVED_LIST+=("$k"); done < <(search_list)
  [[ ${#SAVED_LIST[@]} -gt 0 ]] || { echo "error: could not read the keychain search list" >&2; exit 1; }
  trap restore_list EXIT INT TERM
  security list-keychains -d user -s "${SAVED_LIST[@]}" "$KEYCHAIN"
  local status=0
  codesign --force --deep --sign "$(identity_hash)" --options runtime --entitlements "$ENTITLEMENTS" "$app" \
    || status=$?
  restore_list
  trap - EXIT INT TERM
  return $status
}

case "${1:-}" in
  setup) setup ;;
  available) available ;;
  sign) [[ $# -eq 2 ]] || { echo "usage: $0 sign <app>" >&2; exit 2; }; sign "$2" ;;
  status)
    if available; then
      echo "identity: $(identity_hash) \"$NAME\""
      echo "keychain: $KEYCHAIN"
      [[ -d "$ROOT/dist/IslandBar.app" ]] && echo "dist build: $(codesign -d -r- "$ROOT/dist/IslandBar.app" 2>&1 | sed -n 's/^#* *designated => //p')"
    else
      echo "not set up — builds are ad-hoc and re-prompt for System Audio Recording (Scripts/dev-signing.sh setup)"
      exit 1
    fi
    ;;
  remove)
    [[ -f "$KEYCHAIN" ]] && security delete-keychain "$KEYCHAIN" && echo "deleted $KEYCHAIN"
    rm -f "$PASSFILE"
    ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

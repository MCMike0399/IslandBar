#!/usr/bin/env bash
# Cut a signed IslandBar release that the in-app updater can install.
#
#   Scripts/release.sh <version> [--notes <file>] [--dry-run]
#
# Steps: stamp Resources/Info.plist, ./build.sh, zip the bundle with ditto, sign the zip
# with the Ed25519 release key, commit "Release vX.Y.Z", tag, push main + tag, and publish
# a GitHub release with the zip and its .sig attached. --dry-run stops after
# signing and leaves the tree untouched (build artefacts land in dist/ as usual).
#
# The private key lives outside the repo (default ~/.config/islandbar/update-signing.key,
# override with ISLANDBAR_SIGNING_KEY). Its public half is compiled into
# Sources/IslandBar/Updates/UpdateSignature.swift; the script refuses to sign with a key
# that does not match, because such a release would be rejected by every installed copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=""
NOTES_FILE=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) if [[ -z "$VERSION" ]]; then VERSION="${1#v}"; shift; else echo "unexpected argument: $1" >&2; exit 2; fi ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: Scripts/release.sh <major.minor.patch> [--notes file] [--dry-run]" >&2; exit 2; }
TAG="v$VERSION"

KEY="${ISLANDBAR_SIGNING_KEY:-$HOME/.config/islandbar/update-signing.key}"
[[ -r "$KEY" ]] || { echo "error: release key not found at $KEY (swift Tools/update-signing.swift keygen \"$KEY\")" >&2; exit 1; }
PUBKEY="$(swift Tools/update-signing.swift pubkey "$KEY")"
EMBEDDED="$(sed -n 's/.*publicKeyBase64 = "\(.*\)".*/\1/p' Sources/IslandBar/Updates/UpdateSignature.swift)"
if [[ "$PUBKEY" != "$EMBEDDED" ]]; then
  echo "error: $KEY does not match the public key compiled into UpdateSignature.swift" >&2
  echo "  key file: $PUBKEY" >&2
  echo "  embedded: $EMBEDDED" >&2
  exit 1
fi

if [[ $DRY_RUN -eq 0 ]]; then
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "error: release from main" >&2; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "error: working tree is not clean" >&2; exit 1; }
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "error: tag $TAG already exists" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated" >&2; exit 1; }
  git fetch -q origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "error: main is not in sync with origin/main" >&2; exit 1; }
fi

PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
BUILD_NUMBER="$(( $(git rev-list --count HEAD) + 1 ))"

# Release notes: explicit file, else one bullet per commit since the previous tag.
NOTES="$(mktemp -t islandbar-notes)"
if [[ -n "$NOTES_FILE" ]]; then
  cp "$NOTES_FILE" "$NOTES"
else
  RANGE="${PREVIOUS_TAG:+$PREVIOUS_TAG..}HEAD"
  {
    echo "## What's new in $VERSION"
    echo
    git log --no-merges --format='- %s' "$RANGE" | grep -v '^- Release v' || true
  } > "$NOTES"
fi

# Build before committing anything, so a failed build leaves no stray commit or tag.
if [[ $DRY_RUN -eq 0 ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Resources/Info.plist
  plutil -lint Resources/Info.plist >/dev/null
  if ! ./build.sh; then
    git checkout -- Resources/Info.plist
    echo "error: build failed; Info.plist restored, nothing committed" >&2
    exit 1
  fi
else
  ISLANDBAR_VERSION="$VERSION" ISLANDBAR_BUILD="$BUILD_NUMBER" ./build.sh
fi

# The installer runs the same check on the other end; fail here rather than there.
codesign --verify --deep --strict dist/IslandBar.app
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/IslandBar.app/Contents/Info.plist)" == "$VERSION" ]] \
  || { echo "error: built bundle does not carry version $VERSION" >&2; exit 1; }

ARCHIVE="dist/IslandBar-$VERSION.zip"
rm -f "$ARCHIVE" "$ARCHIVE.sig"
ditto -c -k --keepParent --sequesterRsrc dist/IslandBar.app "$ARCHIVE"
swift Tools/update-signing.swift sign "$KEY" "$ARCHIVE" > "$ARCHIVE.sig"
swift Tools/update-signing.swift verify "$PUBKEY" "$ARCHIVE" "$ARCHIVE.sig" >/dev/null
shasum -a 256 "$ARCHIVE"
echo "signed: $ARCHIVE.sig"
echo "notes:"; sed 's/^/  /' "$NOTES"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "dry run: nothing committed, tagged, pushed or published"
  exit 0
fi

git add Resources/Info.plist
git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "IslandBar $VERSION"
git push -q origin main "$TAG"
if ! gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sig" \
  --title "IslandBar $VERSION" \
  --notes-file "$NOTES" \
  --verify-tag; then
  echo "error: the tag is pushed but the GitHub release was not created. Retry with:" >&2
  echo "  gh release create $TAG $ARCHIVE $ARCHIVE.sig --title 'IslandBar $VERSION' --notes-file $NOTES --verify-tag" >&2
  exit 1
fi
echo "published $TAG"

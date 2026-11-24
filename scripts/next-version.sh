#!/bin/bash
# Prints "VERSION BUILD PREVIOUS_TAG" for the next release. VERSION is the newest vX.Y.Z
# tag with patch + 1, or the Info.plist version if that is higher (or there is no tag).
# BUILD is the commit count.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

semver_sort() { sort -t. -k1,1n -k2,2n -k3,3n; }
bump_patch() { IFS=. read -r major minor patch <<<"$1"; echo "$major.$minor.$((patch + 1))"; }
is_higher() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | semver_sort | tail -1)" == "$1" ]]; }

BASE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
[[ "$BASE" =~ $SEMVER ]] || { echo "CFBundleShortVersionString must be X.Y.Z: $BASE" >&2; exit 1; }

if [[ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" == "true" ]]; then
  echo "Shallow clone: use fetch-depth: 0" >&2
  exit 1
fi

LATEST="$(git -C "$ROOT" tag --list 'v*' | sed 's/^v//' | { grep -E "$SEMVER" || true; } | semver_sort | tail -1)"

if [[ -z "$LATEST" ]] || is_higher "$BASE" "$LATEST"; then
  NEXT="$BASE"
else
  NEXT="$(bump_patch "$LATEST")"
fi

BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
echo "$NEXT $BUILD ${LATEST:+v$LATEST}"

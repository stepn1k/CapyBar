#!/bin/bash
# Rewrites the download line in README.md (between the download:start / download:end
# markers) with the app version from Resources/Info.plist and a build date.
#   scripts/readme-download.sh              today's date (UTC)
#   scripts/readme-download.sh 2026-11-24   a given date
# Run by .github/workflows/build.yml after each release; safe to run by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$ROOT/README.md"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DATE="${1:-$(date -u +%Y-%m-%d)}"
# GitHub Actions sets GITHUB_REPOSITORY (owner/name); the default is for runs by hand.
REPO="${GITHUB_REPOSITORY:-stepn1k/CapyBar}"
URL="https://github.com/$REPO/releases/latest/download/CapyBar.zip"

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Unexpected repository: $REPO" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9A-Za-z.+-]+$ ]] || { echo "Unexpected version: $VERSION" >&2; exit 1; }
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "Date must be YYYY-MM-DD: $DATE" >&2; exit 1; }
grep -q '<!-- download:start -->' "$README" && grep -q '<!-- download:end -->' "$README" \
  || { echo "README.md has no download:start / download:end markers" >&2; exit 1; }

LINE="**[Download CapyBar $VERSION]($URL)** · built $DATE"
LINE="$LINE" perl -0pi -e \
  's/(<!-- download:start -->\n).*?(\n<!-- download:end -->)/$1$ENV{LINE}$2/s' "$README"
echo "README: $LINE"

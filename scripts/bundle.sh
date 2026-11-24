#!/bin/bash
# Builds CapyBar.app (release, ad-hoc signed) into ./build.
#   scripts/bundle.sh            build only
#   scripts/bundle.sh --install  build, quit a running copy, install into /Applications
#   scripts/bundle.sh --zip      build, then pack build/CapyBar.zip to hand to someone else
#
# The flags can be combined.
#
# /Applications matters: MenuBarAgent matches allowlisted apps by bundle ID only for the
# copy LaunchServices resolves for that ID. A copy run from elsewhere cannot keep its
# own icon visible while it holds a restriction.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/CapyBar.app"
DEST="/Applications/CapyBar.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1" 2>/dev/null || true
}

INSTALL=0
ZIP=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --zip) ZIP=1 ;;
    *) echo "Unknown option: $arg (use --install and/or --zip)" >&2; exit 1 ;;
  esac
done

cd "$ROOT"
BUNDLE_ID="$(bundle_id Resources/Info.plist)"
[[ -n "$BUNDLE_ID" ]] || { echo "Resources/Info.plist has no CFBundleIdentifier" >&2; exit 1; }

swift build -c release --product CapyBar
BIN="$(swift build -c release --show-bin-path)/CapyBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CapyBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
# Keep LaunchServices pointing at the /Applications copy only (see the note above).
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if (( ZIP )); then
  # ditto, unlike zip, keeps the code signature and extended attributes intact.
  ZIPFILE="$ROOT/build/CapyBar.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --keepParent "$APP" "$ZIPFILE"
  echo "Packed $ZIPFILE"
  # Published next to the zip; the app's update check reads it (UpdateCheck.swift).
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
  [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || { echo "Unexpected version: $VERSION" >&2; exit 1; }
  [[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "CFBundleVersion must be a whole number: $BUILD" >&2; exit 1; }
  printf '{"version":"%s","build":%s}\n' "$VERSION" "$BUILD" > "$ROOT/build/version.json"
  echo "Wrote $ROOT/build/version.json ($VERSION, build $BUILD)"
fi

(( INSTALL )) || exit 0

# Quit a running copy and wait until it is gone, so it does not keep holding an
# assertion while its bundle is replaced underneath it.
pkill -x CapyBar 2>/dev/null || true
for _ in {1..50}; do pgrep -x CapyBar >/dev/null || break; sleep 0.1; done
if pgrep -x CapyBar >/dev/null; then echo "CapyBar is still running; quit it first" >&2; exit 1; fi

if [[ -L "$DEST" ]]; then echo "Refusing to install: $DEST is a symlink" >&2; exit 1; fi
# Only ever replace our own bundle.
if [[ -e "$DEST" && "$(bundle_id "$DEST/Contents/Info.plist")" != "$BUNDLE_ID" ]]; then
  echo "Refusing to overwrite $DEST: it is not $BUNDLE_ID" >&2
  exit 1
fi

# Stage next to the destination and verify, then swap; the old copy is restored if the
# swap fails, so an interrupted install never leaves a half-copied app behind.
STAGE="$DEST.new.$$"
BACKUP="$DEST.old.$$"
rm -rf "$STAGE"
cp -R "$APP" "$STAGE"
codesign --verify --strict "$STAGE"
if [[ -e "$DEST" ]]; then mv "$DEST" "$BACKUP"; fi
if ! mv "$STAGE" "$DEST"; then
  [[ -e "$BACKUP" ]] && mv "$BACKUP" "$DEST"
  rm -rf "$STAGE"
  echo "Install failed; the previous version was kept" >&2
  exit 1
fi
rm -rf "$BACKUP"
"$LSREGISTER" -f "$DEST"
echo "Installed $DEST"

# An ad-hoc rebuild is a different app to TCC: the old Accessibility entry stays in
# System Settings, switched on but dead. Drop it, so the next launch asks afresh
# instead of leaving it to be removed by hand. Runs after lsregister, because
# tccutil finds the bundle ID through LaunchServices.
if /usr/bin/tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1; then
  echo "Reset privacy permissions of $BUNDLE_ID; grant Accessibility again on launch."
else
  echo "Could not reset privacy permissions of $BUNDLE_ID; remove the old Accessibility entry by hand." >&2
fi

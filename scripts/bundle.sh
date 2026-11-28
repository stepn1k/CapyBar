#!/bin/bash
# Builds CapyBar.app (release) into ./build.
#   scripts/bundle.sh             build only
#   scripts/bundle.sh --install   build, quit a running copy, install into /Applications
#   scripts/bundle.sh --zip       build, then pack build/CapyBar.zip to hand to someone else
#   scripts/bundle.sh --notarize  have Apple notarize the app and staple the ticket to it
#
# The flags can be combined. CAPYBAR_VERSION / CAPYBAR_BUILD override Info.plist.
#
# Signing: with CapyBar's "Developer ID Application" certificate (team CAPYBAR_TEAM_ID,
# default JWZV3K7K8X) in the keychain the app is signed with it, so macOS keeps its
# Accessibility grant across builds and updates. Certificates of other teams are never
# picked on their own; without CapyBar's the app is ad-hoc signed.
# CAPYBAR_SIGN_IDENTITY picks a certificate by name or hash ("-" forces ad-hoc).
# --notarize needs a Developer ID signature and the notarytool keychain profile named
# by CAPYBAR_NOTARY_PROFILE (default capybar-notary), looked up in CAPYBAR_KEYCHAIN if
# set (created with `xcrun notarytool store-credentials`).
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

# The Team ID an app is signed by, or nothing for an ad-hoc or missing signature.
team_id() {
  codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | grep -v '^not set$' || true
}

INSTALL=0
ZIP=0
NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --zip) ZIP=1 ;;
    --notarize) NOTARIZE=1 ;;
    *) echo "Unknown option: $arg (use --install, --zip and/or --notarize)" >&2; exit 1 ;;
  esac
done

cd "$ROOT"
BUNDLE_ID="$(bundle_id Resources/Info.plist)"
[[ -n "$BUNDLE_ID" ]] || { echo "Resources/Info.plist has no CFBundleIdentifier" >&2; exit 1; }
VERSION="${CAPYBAR_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BUILD="${CAPYBAR_BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || { echo "Unexpected version: $VERSION" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "The build must be a whole number: $BUILD" >&2; exit 1; }

# Pick the signing identity before building, so a release without one fails fast.
KEYCHAIN="${CAPYBAR_KEYCHAIN:-}"
TEAM_ID="${CAPYBAR_TEAM_ID:-JWZV3K7K8X}"
IDENTITY="${CAPYBAR_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # Only CapyBar's own team, so a Developer ID of another team in this keychain (an
  # employer's, say) never ends up on CapyBar. The hash, not the name: two certificates
  # may share a name.
  IDENTITY="$(security find-identity -v -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} \
    | awk -v team="($TEAM_ID)\"" \
      'index($0, "\"Developer ID Application: ") && index($0, team) { print $2; exit }')"
  IDENTITY="${IDENTITY:--}"
fi
NOTARY_PROFILE="${CAPYBAR_NOTARY_PROFILE:-capybar-notary}"
if (( NOTARIZE )) && [[ "$IDENTITY" == "-" ]]; then
  echo "--notarize needs the Developer ID Application certificate of team $TEAM_ID in the keychain" >&2
  exit 1
fi

swift build -c release --product CapyBar
BIN="$(swift build -c release --show-bin-path)/CapyBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CapyBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $VERSION" \
  -c "Set :CFBundleVersion $BUILD" \
  "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --options runtime --timestamp=none "$APP"
else
  # Hardened runtime and a secure timestamp are what notarization requires.
  codesign --force --sign "$IDENTITY" ${KEYCHAIN:+--keychain "$KEYCHAIN"} \
    --options runtime --timestamp "$APP"
fi
codesign --verify --strict "$APP"
# Keep LaunchServices pointing at the /Applications copy only (see the note above).
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
TEAM="$(team_id "$APP")"
echo "Built $APP ($VERSION, build $BUILD), signed $( [[ -n "$TEAM" ]] && echo "by team $TEAM" || echo ad-hoc)"

if (( NOTARIZE )); then
  # Apple checks a zip of the app; the ticket it issues is stapled to the app itself,
  # so Gatekeeper accepts it offline and the zip below carries it.
  UPLOAD="$ROOT/build/CapyBar-notarize.zip"
  RESULT="$ROOT/build/notarize.json"
  trap 'rm -f "$UPLOAD" "$RESULT"' EXIT
  rm -f "$UPLOAD"
  ditto -c -k --keepParent "$APP" "$UPLOAD"
  echo "Sending to Apple for notarization (usually a few minutes)…"
  # notarytool reports a timeout as JSON on stderr and a non-zero exit; read both.
  xcrun notarytool submit "$UPLOAD" --keychain-profile "$NOTARY_PROFILE" \
    ${KEYCHAIN:+--keychain "$KEYCHAIN"} --wait --timeout 30m --output-format json \
    > "$RESULT" 2>&1 || true
  rm -f "$UPLOAD"
  STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"
  SUBMISSION="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
  if [[ -z "$STATUS" && -n "$SUBMISSION" ]]; then
    # Apple took longer than the wait (first submissions of a new team can take hours).
    # The submission goes on; the signed app in build/ can be stapled once it passes.
    echo "Apple is still checking submission $SUBMISSION. When it is Accepted:" >&2
    echo "  xcrun notarytool wait $SUBMISSION --keychain-profile $NOTARY_PROFILE" >&2
    echo "  xcrun stapler staple \"$APP\"" >&2
    exit 1
  fi
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization failed: ${STATUS:-$(cat "$RESULT")}" >&2
    if [[ -n "$SUBMISSION" ]]; then
      xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" \
        ${KEYCHAIN:+--keychain "$KEYCHAIN"} >&2 || true
    fi
    exit 1
  fi
  rm -f "$RESULT"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # The same check Gatekeeper makes when someone opens a downloaded copy.
  spctl --assess --type execute --verbose=2 "$APP"
  echo "Notarized $APP"
fi

if (( ZIP )); then
  # ditto, unlike zip, keeps the code signature and extended attributes intact.
  ZIPFILE="$ROOT/build/CapyBar.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --keepParent "$APP" "$ZIPFILE"
  echo "Packed $ZIPFILE"
  # Published next to the zip; the app's update check reads it (UpdateCheck.swift).
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
OLD_TEAM="$( [[ -e "$DEST" ]] && team_id "$DEST" || true)"
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

# TCC ties the Accessibility grant to the signature: for a Developer ID app to its
# bundle ID and team, so a build from the same team keeps it. An ad-hoc build, or one
# replacing a copy signed differently, is a different app to TCC: the old entry stays
# in System Settings, switched on but dead. Drop it, so the next launch asks afresh
# instead of leaving it to be removed by hand. Runs after lsregister, because
# tccutil finds the bundle ID through LaunchServices.
if [[ -n "$TEAM" && "$TEAM" == "$OLD_TEAM" ]]; then
  echo "Kept the Accessibility permission (same team $TEAM)"
elif /usr/bin/tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1; then
  echo "Reset privacy permissions of $BUNDLE_ID; grant Accessibility again on launch."
else
  echo "Could not reset privacy permissions of $BUNDLE_ID; remove the old Accessibility entry by hand." >&2
fi

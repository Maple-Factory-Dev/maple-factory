#!/bin/sh
# Builds the download: Maple Factory.app (with its runner and tmux) in a DMG with an Applications link.
#   apps/mac/scripts/dmg.sh                  → apps/mac/build/Maple-Factory-<version>.dmg
# For one people can open without Gatekeeper warnings, set both:
#   SIGN_IDENTITY="Developer ID Application: …"   signs the app, its helpers and the DMG
#   NOTARY_PROFILE=maple                          a notarytool keychain profile, made once with
#     xcrun notarytool store-credentials maple --apple-id … --team-id … --password <app-specific>
# and the DMG is notarized by Apple and stapled, so it opens offline too.
set -eu
unset CDPATH

here="$(dirname "$(dirname "$(realpath "$0")")")"
app="$("$here/scripts/bundle.sh" release | tail -1)"
version="$(plutil -extract version raw "$here/version.json")"
dmg="$here/build/Maple-Factory-$version.dmg"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "Maple Factory" -srcfolder "$stage" -fs HFS+ -format UDZO -quiet "$dmg"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$dmg"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
  else
    echo "Signed but not notarized (no NOTARY_PROFILE): Gatekeeper will still warn." >&2
  fi
else
  echo "Not signed (no SIGN_IDENTITY): fine on this Mac, but others get a Gatekeeper warning." >&2
fi
echo "$dmg"

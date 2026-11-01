#!/bin/sh
# Archives the iPhone app (Release), signs it for App Store Connect and uploads it to TestFlight.
#   apps/ios/scripts/testflight.sh              archive, export and upload
#   apps/ios/scripts/testflight.sh --no-upload  stop at a signed build/Maple Factory.ipa
# Credentials come from the environment or apps/ios/.env.testflight (gitignored; copy .env.testflight.example):
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH  an App Store Connect API key (TESTFLIGHT.md, step 1.4)
#   BUILD_NUMBER                             optional; the default is a UTC timestamp, so every upload is new
#   SENTRY_AUTH_TOKEN                        optional; uploads the dSYMs to the maple-ios Sentry project
# The first-time setup, the steps only a person can do, is in apps/ios/TESTFLIGHT.md.
# It archives a snapshot of the repo (HEAD plus uncommitted changes to tracked files, in a detached
# worktree at build/src), so a `git pull` during the archive can't mix old and new sources.
# Untracked files aren't in the snapshot: commit or `git add` them first.
set -eu
unset CDPATH

cd "$(dirname "$(dirname "$(realpath "$0")")")"

upload=1
case "${1:-}" in
  "") ;;
  --no-upload) upload=0 ;;
  *) echo "usage: apps/ios/scripts/testflight.sh [--no-upload]" >&2; exit 2 ;;
esac

# The environment wins over the file.
if [ -f .env.testflight ]; then
  for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH BUILD_NUMBER SENTRY_AUTH_TOKEN; do
    eval "set_already=\${$name+x}"
    [ -n "$set_already" ] && continue
    value=$(sed -n "s/^$name=//p" .env.testflight | tail -1)
    # shellcheck disable=SC2163 # exports the variable named by $name
    [ -n "$value" ] && eval "$name=\$value" && export "$name"
  done
fi

# Where `xcrun altool`/Transporter keep keys: AuthKey_<id>.p8 there is used when ASC_KEY_PATH is unset.
if [ -z "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -f "$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8" ]; then
  ASC_KEY_PATH=$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
fi
# shellcheck disable=SC2088 # a literal ~ from the .env file
case "${ASC_KEY_PATH:-}" in "~/"*) ASC_KEY_PATH=$HOME/${ASC_KEY_PATH#"~/"} ;; esac

# Uploading needs the API key. --no-upload can sign with the account signed in to Xcode instead,
# but uses the key when it's there.
missing=
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
  eval "value=\${$name:-}"
  [ -n "$value" ] || missing="$missing $name"
done
if [ -n "$missing" ] && [ "$upload" = 1 ]; then
  {
    echo "Missing App Store Connect API key settings; set them in the environment or apps/ios/.env.testflight:"
    for name in $missing; do
      case $name in
        ASC_KEY_ID) echo "  ASC_KEY_ID     the key's Key ID (TESTFLIGHT.md, 1.4 Make an App Store Connect API key)" ;;
        ASC_ISSUER_ID) echo "  ASC_ISSUER_ID  the Issuer ID above the keys list (TESTFLIGHT.md, 1.4 Make an App Store Connect API key)" ;;
        ASC_KEY_PATH) echo "  ASC_KEY_PATH   the downloaded AuthKey_<id>.p8 (TESTFLIGHT.md, 1.4 Make an App Store Connect API key)" ;;
      esac
    done
    echo "Copy apps/ios/.env.testflight.example to apps/ios/.env.testflight to start (TESTFLIGHT.md, 1.5 Fill in .env.testflight)."
  } >&2
  exit 1
fi
if [ -n "${ASC_KEY_PATH:-}" ] && [ ! -f "$ASC_KEY_PATH" ]; then
  echo "ASC_KEY_PATH is $ASC_KEY_PATH, which isn't a file (TESTFLIGHT.md, 1.4 Make an App Store Connect API key)." >&2
  exit 1
fi

command -v xcodegen >/dev/null || { echo "xcodegen isn't installed: brew install xcodegen" >&2; exit 1; }

# The API key, as xcodebuild's arguments ("$@" from here on).
set --
if [ -z "$missing" ]; then
  set -- -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
fi

BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}
archive=build/MapleFactory.xcarchive
log=build/testflight.log
mkdir -p build
rm -rf "$archive" "build/Maple Factory.ipa"
: >"$log"
build=$(pwd)/build

# Freeze the tree: `git stash create` makes a commit of HEAD plus the tracked changes without touching
# the stash list (it prints nothing when the tree is clean), checked out detached at build/src.
repo=$(git rev-parse --show-toplevel)
ios=$(git rev-parse --show-prefix)
snapshot=$build/src
rev=$(git stash create)
if [ -n "$rev" ]; then base=$(git rev-parse "$rev^1"); dirty=" + local changes"; else rev=$(git rev-parse HEAD); base=$rev; dirty=; fi
drop_snapshot() {
  git -C "$repo" worktree remove --force "$snapshot" 2>/dev/null || rm -rf "$snapshot"
  git -C "$repo" worktree prune
}
drop_snapshot
trap drop_snapshot EXIT
trap 'exit 130' INT TERM
git worktree add --quiet --detach "$snapshot" "$rev" >>"$log" 2>&1 ||
  { echo "Couldn't check out the snapshot at apps/ios/build/src; the log is apps/ios/$log." >&2; exit 1; }
src=$snapshot/${ios%/}
echo "Snapshot: $(git log -1 --format='%h %s' "$base")$dirty"

version=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$src/project.yml" | head -1)
echo "Archiving Maple Factory $version ($BUILD_NUMBER)…"
(cd "$src" && xcodegen generate --quiet)
# SwiftTerm's build-info plugin only stamps its version; skip Xcode's "trust this plugin" prompt.
if ! xcodebuild -project "$src/MapleFactory.xcodeproj" -scheme "Maple Factory" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" -derivedDataPath build/archive \
  -skipPackagePluginValidation -allowProvisioningUpdates "$@" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive >>"$log" 2>&1; then
  grep -E "error:|No profiles|No Accounts|requires a provisioning profile" "$log" | sort -u >&2 || true
  echo "The archive failed; the full log is apps/ios/$log. Signing errors: TESTFLIGHT.md, Troubleshooting." >&2
  exit 1
fi
echo "Archived: apps/ios/$archive"

options=build/ExportOptions.plist
cp scripts/ExportOptions.plist "$options"
[ "$upload" = 1 ] || plutil -replace destination -string export "$options"

if [ "$upload" = 1 ]; then echo "Signing and uploading to App Store Connect…"; else echo "Signing (no upload)…"; fi
if ! xcodebuild -exportArchive -archivePath "$archive" -exportPath build -exportOptionsPlist "$options" \
  -allowProvisioningUpdates "$@" >>"$log" 2>&1; then
  grep -E "error:|Error Domain|No signing certificate|No Accounts|No profiles|already been used|bundle version" "$log" | sort -u >&2 || true
  echo "The export failed; the full log is apps/ios/$log. Common causes: TESTFLIGHT.md, Troubleshooting." >&2
  exit 1
fi

if [ -n "${SENTRY_AUTH_TOKEN:-}" ]; then
  if command -v sentry-cli >/dev/null; then
    echo "Uploading dSYMs to Sentry (maple-ios)…"
    sentry-cli debug-files upload --org andrea-fomera --project maple-ios --include-sources "$archive/dSYMs"
  else
    echo "SENTRY_AUTH_TOKEN is set but sentry-cli isn't installed (brew install getsentry/tools/sentry-cli); skipped the dSYMs." >&2
  fi
fi

if [ "$upload" = 1 ]; then
  echo "Uploaded Maple Factory $version ($BUILD_NUMBER). App Store Connect processes it for 5–30 minutes,"
  echo "then it's in TestFlight for the internal testers (TESTFLIGHT.md, part 2)."
else
  echo "Signed: apps/ios/build/Maple Factory.ipa ($version, build $BUILD_NUMBER). Run without --no-upload to send it."
fi

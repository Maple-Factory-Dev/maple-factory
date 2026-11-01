#!/bin/sh
# Builds the iPhone app and boots it in the simulator: xcodegen generate, xcodebuild, boot, install, launch.
#   apps/ios/scripts/run-ios.sh [launch args…]             e.g. -demo YES -tab goals
#   apps/ios/scripts/run-ios.sh shot <dir> [launch args…]  also saves a screenshot to <dir>, named after the args
# SIM picks the simulator (default "iPhone 18 Pro"; a booted one of that name first), CONFIG the build
# configuration (default Debug; Release reports errors to Sentry), BUILD=0 skips generating and building.
set -eu
unset CDPATH

# Takes turns on the simulator with other sessions on this machine (docs/resource-locks.md): runs
# itself again under `maple-runner lock ios-simulator`, or straight on without a runner that has it.
if [ -z "${MAPLE_LOCKED:-}" ]; then
  runner=${MAPLE_RUNNER:-$(command -v maple-runner || true)}
  if [ -n "$runner" ] && "$runner" lock --help >/dev/null 2>&1; then
    export MAPLE_LOCKED=1
    exec "$runner" lock ios-simulator -- "$(realpath "$0")" "$@"
  fi
fi

cd "$(dirname "$(dirname "$(realpath "$0")")")"
SIM=${SIM:-iPhone 18 Pro}
CONFIG=${CONFIG:-Debug}
BUNDLE=dev.maplefactory.ios

shot=
if [ "${1:-}" = shot ]; then
  shot=${2:?usage: run-ios.sh shot <dir> [launch args…]}
  shift 2
fi

# Several simulators can share a name; a booted one wins, else the first.
udid=$(xcrun simctl list devices available | grep -F "    $SIM (" | sort -k1,1 | awk -v want="$SIM" '
  { line = $0; sub(/^ +/, "", line) }
  substr(line, 1, length(want) + 2) == want " (" {
    match(line, /\([0-9A-F-]{36}\)/); id = substr(line, RSTART + 1, RLENGTH - 2)
    if (line ~ /\(Booted\)/) { print id; found = 1; exit }
    if (!first) first = id
  }
  END { if (!found && first) print first }')
[ -n "$udid" ] || { echo "No simulator named \"$SIM\" (xcrun simctl list devices)." >&2; exit 1; }

if [ "${BUILD:-1}" != 0 ]; then
  xcodegen generate --quiet
  log=build/xcodebuild.log
  mkdir -p build
  xcodebuild -project MapleFactory.xcodeproj -scheme "Maple Factory" -configuration "$CONFIG" \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build -skipPackagePluginValidation build >"$log" 2>&1 || true
  grep -E "error:|warning: .*/apps/ios/|BUILD (SUCCEEDED|FAILED)" "$log" || true
  grep -q "BUILD SUCCEEDED" "$log" || { echo "The build failed: $log" >&2; exit 1; }
fi

xcrun simctl boot "$udid" 2>/dev/null || true
# The Simulator window, when Xcode has one; simctl runs the device headless without it.
open -b com.apple.iphonesimulator --args -CurrentDeviceUDID "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "build/Build/Products/$CONFIG-iphonesimulator/Maple Factory.app"
xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE" "$@"

if [ -n "$shot" ]; then
  mkdir -p "$shot"
  name=$(printf '%s' "${*:-app}" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//; s/-$//')
  sleep "${SHOT_DELAY:-4}"
  xcrun simctl io "$udid" screenshot --type=png "$shot/$name.png" >/dev/null
  echo "Saved $shot/$name.png"
fi

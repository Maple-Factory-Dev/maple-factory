#!/bin/sh
# Builds MapleKit (the wire protocol, factory API and sign-in storage the Mac and iOS apps share) for
# the iOS simulator, so nothing AppKit, SwiftUI, Sparkle or SwiftTerm creeps into it.
#   apps/mac/scripts/check-ios.sh
set -eu
unset CDPATH

cd "$(dirname "$(dirname "$(realpath "$0")")")"
xcodebuild -scheme MapleKit -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios -quiet build
echo "MapleKit builds for iOS."

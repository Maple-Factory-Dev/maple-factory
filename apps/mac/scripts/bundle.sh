#!/bin/sh
# Builds Maple Factory.app from the Swift package: the binary, its resource bundles, the icon, an
# Info.plist that registers maplefactory:// (task links from the factory's /t/<id> pages open the app),
# and in Contents/Helpers the runner and tmux, which "Add this Mac" installs. Apple silicon only.
#   apps/mac/scripts/bundle.sh [debug|release]      → apps/mac/build/Maple Factory.app
# Signs ad hoc unless SIGN_IDENTITY names a Developer ID ("Developer ID Application: …"). The version
# is version.json's (scripts/release.mjs bumps it); Sparkle checks UPDATES_URL/appcast.xml for newer ones.
set -eu
unset CDPATH

config="${1:-release}"
here="$(dirname "$(dirname "$(realpath "$0")")")"
root="$(dirname "$(dirname "$here")")"
cd "$here"

swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)"
version="$(plutil -extract version raw "$here/version.json")"
build="$(plutil -extract build raw "$here/version.json")"
updates="${UPDATES_URL:-https://updates.maplefactory.dev}"
# Crash and error reports go to Maple Factory's Sentry project (ErrorReports.swift); debug builds send none.
sentry_dsn="$(plutil -extract projects.mac.dsn raw "$root/server/web/sentry.json")"

app="$here/build/Maple Factory.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/MapleFactory" "$app/Contents/MacOS/MapleFactory"
for bundle in "$bin"/*.bundle; do cp -R "$bundle" "$app/Contents/Resources/"; done
# Sparkle, where the binary looks for it. ditto keeps the framework's symlinks.
mkdir -p "$app/Contents/Frameworks"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/MapleFactory"

# The runner (Apple silicon, like the app), and a tmux that needs nothing from Homebrew.
mkdir -p "$app/Contents/Helpers"
target=aarch64-apple-darwin
rustup target list --installed | grep -qx "$target" || rustup target add "$target"
(cd "$root/runner" && cargo build --release --target "$target" --quiet)
cp "$root/runner/target/$target/release/maple-runner" "$app/Contents/Helpers/maple-runner"
cp "$("$here/scripts/build-tmux.sh")" "$app/Contents/Helpers/tmux"

# The icon: every size iconutil wants, from the 1254px source.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$root/assets/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$root/assets/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Maple Factory</string>
  <key>CFBundleDisplayName</key><string>Maple Factory</string>
  <key>CFBundleIdentifier</key><string>dev.maplefactory.app</string>
  <key>CFBundleExecutable</key><string>MapleFactory</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${build}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>MapleSentryDSN</key><string>${sentry_dsn}</string>
  <key>SUFeedURL</key><string>${updates}/appcast.xml</string>
  <key>SUPublicEDKey</key><string>g9Kk8H1vNiqHXzA8sI6+55GCkZ2vc321tJOsbbNDdCY=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>3600</integer>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>dev.maplefactory.task</string>
      <key>CFBundleURLSchemes</key><array><string>maplefactory</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Inside out: the helpers, Sparkle's (as its docs order them), the framework, then the app.
sign() { codesign --force --sign "${SIGN_IDENTITY:--}" ${SIGN_IDENTITY:+--options runtime --timestamp} "$@"; }
for helper in "$app/Contents/Helpers/"*; do sign "$helper"; done
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign "$app"
# Tell Launch Services about it, so maplefactory:// links open this copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"

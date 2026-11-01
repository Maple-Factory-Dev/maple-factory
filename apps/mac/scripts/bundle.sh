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

# Each stage says how long it took (on stderr: stdout's last line is the app's path, for dmg.sh).
t0=$(date +%s)
elapsed() { if [ "$1" -ge 60 ]; then printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); else printf '%ds' "$1"; fi; }
stage() { now=$(date +%s); echo "  ✓ $1 in $(elapsed $((now - t0)))" >&2; t0=$now; }

mkdir -p "$here/build"
logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

# The runner (Apple silicon, like the app), a tmux that needs nothing from Homebrew, and the icon need
# nothing from Swift, so they build alongside it. Each logs to its own file, shown if it fails.
target=aarch64-apple-darwin
rustup target list --installed | grep -qx "$target" || rustup target add "$target"
alongside() { name="$1"; shift; start=$(date +%s); "$@" > "$logs/$name.log" 2>&1 || return; echo $(($(date +%s) - start)) > "$logs/$name.time"; }
alongside runner sh -c 'cd "$1/runner" && cargo build --release --target "$2" --quiet' sh "$root" "$target" & runner_job=$!
alongside tmux "$here/scripts/build-tmux.sh" & tmux_job=$!
# The icon: every size iconutil wants, from the 1254px source.
icon() {
  iconset="$logs/AppIcon.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$root/assets/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$root/assets/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$logs/AppIcon.icns"
}
alongside icon icon & icon_job=$!

# One swift build. Its products are in .build/<config> (a link SwiftBuild keeps to out/Products/<Config>);
# release.mjs reads the path from build/bin-path rather than asking swift again.
echo "  \$ swift build -c $config" >&2
swift build -c "$config"
bin="$(cd "$here/.build/$config" 2>/dev/null && pwd -P)" || bin="$(swift build -c "$config" --show-bin-path)"
echo "$bin" > "$here/build/bin-path"
stage "swift build"

# Any of the three failing stops here, as it would have run in line.
for job in runner tmux icon; do
  eval "pid=\$${job}_job"
  if ! wait "$pid"; then echo "bundle.sh: building the $job failed:" >&2; cat "$logs/$job.log" >&2; exit 1; fi
  echo "  ✓ $job in $(elapsed "$(cat "$logs/$job.time")") (alongside swift)" >&2
done
t0=$(date +%s)
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

mkdir -p "$app/Contents/Helpers"
cp "$root/runner/target/$target/release/maple-runner" "$app/Contents/Helpers/maple-runner"
cp "$(tail -1 "$logs/tmux.log")" "$app/Contents/Helpers/tmux"
cp "$logs/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

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
stage "assembling and signing"
# Tell Launch Services about it, so maplefactory:// links open this copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"

#!/bin/sh
# Builds Maple Factory.app from the Swift package: the binary, its resource bundles, the icon, and an
# Info.plist that registers maplefactory:// (task links from the factory's /t/<id> pages open the app).
#   apps/mac/scripts/bundle.sh [debug|release]      → apps/mac/build/Maple Factory.app
# Signs ad hoc unless SIGN_IDENTITY names a Developer ID ("Developer ID Application: …").
set -eu
unset CDPATH

config="${1:-release}"
here="$(dirname "$(dirname "$(realpath "$0")")")"
root="$(dirname "$(dirname "$here")")"
cd "$here"

swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)"
version="$(git -C "$root" describe --tags --always 2>/dev/null || echo 0.0.0)"

app="$here/build/Maple Factory.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/MapleFactory" "$app/Contents/MacOS/MapleFactory"
for bundle in "$bin"/*.bundle; do cp -R "$bundle" "$app/Contents/Resources/"; done

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
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
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

codesign --force --deep --sign "${SIGN_IDENTITY:--}" ${SIGN_IDENTITY:+--options runtime --timestamp} "$app"
# Tell Launch Services about it, so maplefactory:// links open this copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"

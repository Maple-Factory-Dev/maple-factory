#!/bin/sh
# Builds the Android app and runs it on an emulator: gradle assembleDebug, boot, install, launch.
#   apps/android/scripts/run-android.sh [launch args…]             e.g. -demo YES -tab goals
#   apps/android/scripts/run-android.sh shot <dir> [launch args…]  also saves a screenshot to <dir>, named after the args
# Launch args are the iPhone app's (-demo, -tab, -goal, -task, -onboardingURL, -onboardingContinue, -devAs),
# passed as intent extras. On the emulator the Mac is 10.0.2.2: -onboardingURL 10.0.2.2:8788 for the dev stack.
# AVD picks the emulator (default: a running one, else the first `emulator -list-avds` lists); it boots
# headless unless WINDOW=1. BUILD=0 skips building; JAVA_HOME defaults to a JDK 17–21 (Gradle 9.2's range).
set -eu
unset CDPATH

cd "$(dirname "$(dirname "$(realpath "$0")")")"
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
export ANDROID_HOME="$SDK"
ADB="$SDK/platform-tools/adb"
APP=dev.maplefactory.android

shot=
if [ "${1:-}" = shot ]; then
  shot=${2:?usage: run-android.sh shot <dir> [launch args…]}
  shift 2
fi

if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then
  JAVA_HOME=$(/usr/libexec/java_home -v 21 2>/dev/null || /usr/libexec/java_home -v 17)
  export JAVA_HOME
fi

if [ "${BUILD:-1}" != 0 ]; then
  ./gradlew -q assembleDebug
fi

# A running emulator, else boot one.
serial=$("$ADB" devices | awk '/^emulator-[0-9]+\tdevice$/ { print $1; exit }')
if [ -z "$serial" ]; then
  avd=${AVD:-$("$SDK/emulator/emulator" -list-avds | head -1)}
  [ -n "$avd" ] || { echo "No emulator: make one in Android Studio's Device Manager." >&2; exit 1; }
  window=-no-window
  [ "${WINDOW:-0}" = 1 ] && window=
  nohup "$SDK/emulator/emulator" -avd "$avd" $window -no-snapshot-save -no-boot-anim >/tmp/maple-emulator.log 2>&1 &
  "$ADB" wait-for-device
  serial=$("$ADB" devices | awk '/^emulator-[0-9]+/ { print $1; exit }')
fi
export ANDROID_SERIAL="$serial"
until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 1; done

"$ADB" install -r -t app/build/outputs/apk/debug/app-debug.apk >/dev/null

# -key value pairs become string extras: -demo YES → --es demo YES.
extras=
name=$*
while [ $# -gt 0 ]; do
  key=${1#-}
  value=${2:-}
  extras="$extras --es $key '$value'"
  shift 2 2>/dev/null || shift
done
"$ADB" shell am force-stop "$APP"
eval "\"\$ADB\" shell am start -W -n $APP/dev.maplefactory.MainActivity $extras" >/dev/null
echo "Launched on $serial"

if [ -n "$shot" ]; then
  mkdir -p "$shot"
  file=$(printf '%s' "${name:-app}" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//; s/-$//')
  sleep "${SHOT_DELAY:-4}"
  "$ADB" exec-out screencap -p >"$shot/$file.png"
  echo "Saved $shot/$file.png"
fi

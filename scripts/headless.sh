#!/bin/sh
# Tests the Mac app without taking over the screen: it runs as a background app with no Dock icon,
# its window off screen, and renders PNGs. Your mouse, keyboard and frontmost app are left alone.
#   scripts/headless.sh shot <out-dir> [app flags…]    # e.g. -destination inbox -actions 'approve:ATL-147; shot:approved'
#   scripts/headless.sh video <out.mp4> [app flags…]   # -frames 60 by default; needs ffmpeg
#   scripts/headless.sh stack up|down|port|logs        # an isolated dev stack (MAPLE_DEV_INSTANCE, default `agent`)
#   scripts/headless.sh live <out-dir> [app flags…]    # shot, signed in to that stack
# App flags: -appearance light|dark|both, -settle 1.5, -timeout 60, -width/-height, -name, -fps 10, plus
# every launch flag the app has (-destination, -task, -focus, -actions, …). See apps/mac/Sources/MapleFactory/Headless.swift.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/apps/mac"
export MAPLE_DEV_INSTANCE=${MAPLE_DEV_INSTANCE:-agent}

build() {
  (cd "$APP" && swift build -q) >&2
  BIN="$(cd "$APP" && swift build --show-bin-path)/MapleFactory"
}

# Runs the app until it writes done.json; prints its PNGs, or its errors and exits 1.
snapshot() {
  OUT=$1; shift
  mkdir -p "$OUT"
  OUT=$(cd "$OUT" && pwd)
  rm -f "$OUT/done.json"
  build
  "$BIN" -snapshot "$OUT" -instance "headless-$$" "$@" >"$OUT/app.log" 2>&1 || true
  if [ ! -f "$OUT/done.json" ]; then
    echo "headless: the app quit without done.json; see $OUT/app.log" >&2
    tail -20 "$OUT/app.log" >&2
    exit 1
  fi
  node -e '
    const done = require(process.argv[1]);
    done.files.filter(f => !/frame-\d+\.png$/.test(f)).forEach(f => console.log(f));
    const frames = done.files.filter(f => /frame-\d+\.png$/.test(f)).length;
    if (frames) console.log(`${frames} frames`);
    done.errors.forEach(e => console.error("headless: " + e));
    process.exit(done.errors.length ? 1 : 0);
  ' "$OUT/done.json"
}

case "$1" in
shot)
  shift; [ -n "$1" ] || { echo "usage: $0 shot <out-dir> [app flags…]" >&2; exit 2; }
  snapshot "$@"
  ;;
live)
  shift; [ -n "$1" ] || { echo "usage: $0 live <out-dir> [app flags…]" >&2; exit 2; }
  OUT=$1; shift
  PORT=$("$ROOT/scripts/dev-stack.sh" port)
  curl -sf "localhost:$PORT/healthz" >/dev/null || { echo "headless: no dev stack on :$PORT; run $0 stack up" >&2; exit 1; }
  snapshot "$OUT" -onboarding YES -onboardingURL "localhost:$PORT" -onboardingContinue YES "$@"
  ;;
video)
  shift; [ -n "$1" ] || { echo "usage: $0 video <out.mp4> [app flags…]" >&2; exit 2; }
  command -v ffmpeg >/dev/null || { echo "headless: video needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }
  MP4=$1; shift
  FRAMES=$(mktemp -d "${TMPDIR:-/tmp}/headless-frames.XXXXXX")
  snapshot "$FRAMES" -frames 60 -fps 10 "$@" >/dev/null
  ffmpeg -loglevel error -y -framerate 10 -i "$FRAMES/frame-%04d.png" -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -pix_fmt yuv420p "$MP4"
  echo "$MP4"
  ;;
stack)
  shift; exec "$ROOT/scripts/dev-stack.sh" "${@:-up}"
  ;;
*)
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
  ;;
esac

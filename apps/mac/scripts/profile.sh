#!/bin/sh
# Measures the Mac app's CPU and memory, headless, against a local factory of its own:
#   apps/mac/scripts/profile.sh run <out-dir>                 # → <out-dir>/summary.txt, printed as a table
#   apps/mac/scripts/profile.sh compare <before-dir> <after-dir>
# `run` builds the app in release, brings up a dev stack (MAPLE_DEV_INSTANCE, default `profile`; its runner
# is stopped, so tasks stay where the seed left them), seeds it with scripts/profile-load.mjs, then plays
# the app (scripts/headless.sh's driver, signed in) through:
#   idle      the goal's page open, nothing happening: CPU over 20s
#   updates   a task edit every 100ms and a teammate moving every 250ms: CPU over 20s
#   browse    each proven task's Overview, its screenshot and video large, Diff, Statistics, twice over:
#             footprint right after, and again 30s later (steady), with the run's peak
#   countdown the demo factory with an auto-merge counting down on screen: CPU over 7s
# Each phase also leaves a `sample` of the process (<phase>.sample.txt) in <out-dir>.
set -eu
unset CDPATH
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
export MAPLE_DEV_INSTANCE=${MAPLE_DEV_INSTANCE:-profile}

# CPU seconds the process has used so far (ps's [[hh:]mm:]ss.cc).
cputime() { ps -o time= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'; }
# Its CPU % over the next $2 seconds (100 = one core).
cpu() {
  a=$(cputime "$1"); sleep "$2"; b=$(cputime "$1")
  awk -v a="$a" -v b="$b" -v t="$2" 'BEGIN { printf "%.1f", (b - a) / t * 100 }'
}
# vmmap's physical footprint, or its peak, in MB.
footprint() {
  vmmap --summary "$1" 2>/dev/null | awk -v want="$2" '
    /^Physical footprint:/ && want == "now" { v = $3 } /^Physical footprint \(peak\):/ && want == "peak" { v = $4 }
    END { n = v + 0; if (v ~ /G$/) n *= 1024; if (v ~ /K$/) n /= 1024; printf "%.0f", n }'
}
# How many of the main thread's samples were spent waiting for an event, of how many in all.
main_idle() {
  awk '
    /^Call graph:/ { graph = 1 }
    graph && /com\.apple\.main-thread/ && !total { match($0, /[0-9]+ Thread_/); total = substr($0, RSTART, RLENGTH) + 0; main = 1; next }
    main && /^    [0-9]+ Thread_|^Total number in stack/ { main = 0 }
    main && /mach_msg2_trap|mach_msg_trap/ { match($0, /[0-9]+ +mach_msg/); n = substr($0, RSTART, RLENGTH) + 0; if (n > idle) idle = n }
    END { printf "%d of %d", idle, total }' "$1"
}
# Waits for the app to write <name>.png, the marker of a phase; fails if the app quits first.
until_marker() {
  i=0
  while [ ! -f "$OUT/$1.png" ]; do
    kill -0 "$PID" 2>/dev/null || { echo "profile: the app quit before $1; see $OUT/app.log" >&2; exit 1; }
    i=$((i + 1)); [ $i -lt 3000 ] || { echo "profile: no $1 after 300s" >&2; exit 1; }
    sleep 0.1
  done
}
launch() {
  "$BIN" -snapshot "$OUT" -instance "profile-$$" -timeout 600 -settle 0.5 "$@" >>"$OUT/app.log" 2>&1 &
  PID=$!
}
finish_app() {
  wait "$PID" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/dev.maplefactory.headless.profile-$$.plist"
}
record() { printf '%s\t%s\n' "$1" "$2" >>"$OUT/summary.txt"; }

run() {
  OUT=$1
  mkdir -p "$OUT"
  OUT=$(cd "$OUT" && pwd)
  rm -f "$OUT"/*.png "$OUT/summary.txt" "$OUT/app.log" "$OUT/done.json"

  (cd "$HERE" && swift build -c release -q) >&2
  BIN="$(cd "$HERE" && swift build -c release --show-bin-path)/MapleFactory"

  PORT=$("$ROOT/scripts/dev-stack.sh" port)
  if ! curl -sf "localhost:$PORT/healthz" >/dev/null; then
    "$ROOT/scripts/dev-stack.sh" up >&2
    PORT=$("$ROOT/scripts/dev-stack.sh" port)
  fi
  # No runner: a task the seed made mustn't be planned or built while it's measured.
  LOGS=${TMPDIR:-/tmp}/maple-dev-$MAPLE_DEV_INSTANCE
  [ -f "$LOGS/runner.pid" ] && { kill "$(cat "$LOGS/runner.pid")" 2>/dev/null || true; rm -f "$LOGS/runner.pid"; }
  BASE="http://localhost:$PORT"
  node "$HERE/scripts/profile-load.mjs" seed "$BASE" "$OUT/seed.json"
  GOAL=$(node -e 'console.log(require(process.argv[1]).goal)' "$OUT/seed.json")
  PROOFS=$(node -e 'console.log(require(process.argv[1]).proofs.join(" "))' "$OUT/seed.json")

  # The browse: each proven task opened, its proofs shown large, its Diff, then Statistics and back.
  browse=""
  for _ in 1 2; do
    for id in $PROOFS; do
      browse="$browse dblclick:$id; wait:1.5; lightbox:image; wait:1; lightbox:zoom:3; wait:0.5; lightbox:close; lightbox:video; wait:1.5; lightbox:close;"
      browse="$browse tab:diff; wait:1; tab:overview; unfocus; wait:0.5; go:statistics; wait:1; go:$GOAL; wait:0.5;"
    done
  done

  echo "profile: idle, updates and browse against $BASE" >&2
  launch -onboarding YES -onboardingURL "localhost:$PORT" -onboardingContinue YES -destination "$GOAL" \
    -actions "ready:1; go:$GOAL; wait:3; shot:p-idle; wait:26; shot:p-updates; wait:28; shot:p-browse; $browse shot:p-browsed; wait:34; shot:p-end"
  until_marker p-idle
  record pid "$PID"
  sample "$PID" 5 -file "$OUT/idle.sample.txt" >/dev/null 2>&1 &
  record "idle_cpu_pct" "$(cpu "$PID" 20)"
  wait $! || true
  record "idle_footprint_mb" "$(footprint "$PID" now)"

  until_marker p-updates
  node "$HERE/scripts/profile-load.mjs" load "$BASE" 25 >"$OUT/load.log" &
  LOAD=$!
  sleep 2
  sample "$PID" 5 -file "$OUT/updates.sample.txt" >/dev/null 2>&1 &
  record "updates_cpu_pct" "$(cpu "$PID" 20)"
  wait $! || true
  wait "$LOAD"
  record "updates_footprint_mb" "$(footprint "$PID" now)"
  record "updates_sent" "$(cat "$OUT/load.log")"

  until_marker p-browsed
  record "browse_footprint_mb" "$(footprint "$PID" now)"
  sleep 30
  record "steady_footprint_mb" "$(footprint "$PID" now)"
  record "peak_footprint_mb" "$(footprint "$PID" peak)"
  sample "$PID" 3 -file "$OUT/steady.sample.txt" >/dev/null 2>&1 || true
  finish_app

  # The countdown: the demo factory's ATL-141 made ready to auto-merge (10s), measured while it counts.
  echo "profile: auto-merge countdown (demo factory)" >&2
  launch -focus ATL-141 -actions "wait:2; shot:p-before-countdown; reviews:low:0; reviews:medium:0; reviews:high:0; accept:Auth overhaul:High; green:ATL-141; shot:p-countdown; wait:12; shot:p-counted"
  until_marker p-before-countdown
  record "screen_idle_cpu_pct" "$(cpu "$PID" 3)"
  until_marker p-countdown
  sample "$PID" 5 -file "$OUT/countdown.sample.txt" >/dev/null 2>&1 &
  record "countdown_cpu_pct" "$(cpu "$PID" 7)"
  wait $! || true
  record "countdown_main_idle_samples" "$(main_idle "$OUT/countdown.sample.txt")"
  finish_app

  table "$OUT/summary.txt"
}

LABELS='idle_cpu_pct|Idle CPU (%)
updates_cpu_pct|CPU during live updates (%)
idle_footprint_mb|Footprint idle (MB)
updates_footprint_mb|Footprint after updates (MB)
browse_footprint_mb|Footprint right after browsing (MB)
steady_footprint_mb|Footprint 30s later, steady (MB)
peak_footprint_mb|Peak footprint (MB)
countdown_cpu_pct|CPU with a countdown on screen (%)
countdown_main_idle_samples|Main thread idle, countdown (samples)
updates_sent|Load'

value() { awk -F'\t' -v k="$2" '$1 == k { print $2 }' "$1"; }

table() {
  echo "$LABELS" | while IFS='|' read -r key label; do printf '%-42s %s\n' "$label" "$(value "$1" "$key")"; done
}

compare() {
  printf '| %s | %s | %s |\n|---|---:|---:|\n' "Measure" "Before" "After"
  echo "$LABELS" | while IFS='|' read -r key label; do
    printf '| %s | %s | %s |\n' "$label" "$(value "$1/summary.txt" "$key")" "$(value "$2/summary.txt" "$key")"
  done
}

case "${1:-}" in
run) shift; [ -n "${1:-}" ] || { echo "usage: $0 run <out-dir>" >&2; exit 2; }; run "$1" ;;
compare) shift; [ $# -eq 2 ] || { echo "usage: $0 compare <before-dir> <after-dir>" >&2; exit 2; }; compare "$1" "$2" ;;
*) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

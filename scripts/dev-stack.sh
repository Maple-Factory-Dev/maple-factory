#!/bin/sh
# A local factory to click around in: the server on :8788 (signed in as DEV_LOGIN) and one
# throwaway runner, `dev-mac`, living in /tmp/mfh so it never touches your real ~/.config/maple.
#   scripts/dev-stack.sh up | down | logs
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT=${MAPLE_PORT:-8788}
RUNNER_HOME=/tmp/mfh          # short: the tmux socket path must stay under 104 bytes
LOGS=${TMPDIR:-/tmp}/maple-dev
mkdir -p "$LOGS"

case "${1:-up}" in
up)
  [ -f "$ROOT/server/.dev.vars" ] || cp "$ROOT/server/.dev.vars.example" "$ROOT/server/.dev.vars"
  (cd "$ROOT/server" && npx wrangler d1 migrations apply maple --local >/dev/null)
  (cd "$ROOT/server" && nohup npx wrangler dev --port "$PORT" >"$LOGS/server.log" 2>&1 &)
  for _ in $(seq 1 40); do curl -sf "localhost:$PORT/healthz" >/dev/null && break; sleep 0.5; done
  (cd "$ROOT/runner" && cargo build -q)
  if [ ! -f "$RUNNER_HOME/.config/maple/runner.json" ]; then
    mkdir -p "$RUNNER_HOME"
    CODE=$(curl -sf -X POST "localhost:$PORT/api/machines/enroll" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).code))')
    HOME=$RUNNER_HOME "$ROOT/runner/target/debug/maple-runner" enroll --url "http://localhost:$PORT" --code "$CODE" --runner-id dev-mac >/dev/null
  fi
  HOME=$RUNNER_HOME RUST_LOG=info nohup "$ROOT/runner/target/debug/maple-runner" >"$LOGS/runner.log" 2>&1 &
  echo "server http://localhost:$PORT · runner dev-mac · logs in $LOGS"
  ;;
down)
  pkill -f "maple-runner$" 2>/dev/null || true
  pkill -f "wrangler dev --port $PORT" 2>/dev/null || true
  tmux -S "$RUNNER_HOME/.config/maple/tmux/maple.sock" kill-server 2>/dev/null || true
  ;;
logs)
  tail -f "$LOGS/server.log" "$LOGS/runner.log"
  ;;
esac

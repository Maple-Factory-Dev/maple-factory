#!/bin/sh
# A local factory to click around in: the server on :8788 (signed in as DEV_LOGIN) and one
# throwaway runner, `dev-mac`, living in /tmp/mfh so it never touches your real ~/.config/maple.
#   scripts/dev-stack.sh up | down | logs | port
# MAPLE_DEV_INSTANCE=agent runs a second, separate stack beside it: its own runner home
# (/tmp/mfh-agent), D1 state, logs, runner id (agent-mac) and a free port unless MAPLE_PORT says.
# `down` stops only what this instance started (by pid), never another instance or a real runner.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTANCE=${MAPLE_DEV_INSTANCE:-dev}
if [ "$INSTANCE" = dev ]; then
  RUNNER_HOME=/tmp/mfh          # short: the tmux socket path must stay under 104 bytes
  LOGS=${TMPDIR:-/tmp}/maple-dev
  RUNNER_ID=dev-mac
  PERSIST=
else
  RUNNER_HOME=/tmp/mfh-$INSTANCE
  LOGS=${TMPDIR:-/tmp}/maple-dev-$INSTANCE
  RUNNER_ID=$INSTANCE-mac
  PERSIST="--persist-to $LOGS/state"
fi
mkdir -p "$LOGS"

free_port() { node -e 'const s=require("net").createServer().listen(0,()=>{console.log(s.address().port);s.close()})'; }
if [ -n "$MAPLE_PORT" ]; then PORT=$MAPLE_PORT
elif [ -f "$LOGS/port" ]; then PORT=$(cat "$LOGS/port")
elif [ "$INSTANCE" = dev ]; then PORT=8788
else PORT=$(free_port)
fi

# A pid and everything under it (npx → wrangler → workerd).
kill_tree() {
  for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$child"; done
  kill "$1" 2>/dev/null || true
}
stop() {
  [ -f "$LOGS/$1.pid" ] || return 0
  kill_tree "$(cat "$LOGS/$1.pid")"
  rm -f "$LOGS/$1.pid"
}

case "${1:-up}" in
up)
  # Not a .dev.vars.example: the Deploy to Cloudflare button would ask for everything in one.
  [ -f "$ROOT/server/.dev.vars" ] || printf 'DEV_LOGIN=%s\nGITHUB_ORG=your-org\n' "${DEV_LOGIN:-$(whoami)}" >"$ROOT/server/.dev.vars"
  stop server; stop runner
  echo "$PORT" >"$LOGS/port"
  (cd "$ROOT/server" && npx wrangler d1 migrations apply maple --local $PERSIST >/dev/null)
  (cd "$ROOT/server" && exec nohup npx wrangler dev --port "$PORT" --inspector-port 0 $PERSIST) >"$LOGS/server.log" 2>&1 </dev/null &
  echo $! >"$LOGS/server.pid"
  for _ in $(seq 1 40); do curl -sf "localhost:$PORT/healthz" >/dev/null && break; sleep 0.5; done
  (cd "$ROOT/runner" && cargo build -q)
  if [ ! -f "$RUNNER_HOME/.config/maple/runner.json" ]; then
    mkdir -p "$RUNNER_HOME"
    CODE=$(curl -sf -X POST "localhost:$PORT/api/machines/enroll" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).code))')
    HOME=$RUNNER_HOME "$ROOT/runner/target/debug/maple-runner" enroll --url "http://localhost:$PORT" --code "$CODE" --runner-id "$RUNNER_ID" >/dev/null
  fi
  HOME=$RUNNER_HOME RUST_LOG=info nohup "$ROOT/runner/target/debug/maple-runner" >"$LOGS/runner.log" 2>&1 </dev/null &
  echo $! >"$LOGS/runner.pid"
  echo "server http://localhost:$PORT · runner $RUNNER_ID · logs in $LOGS"
  ;;
down)
  stop runner
  stop server
  tmux -S "$RUNNER_HOME/.config/maple/tmux/maple.sock" kill-server 2>/dev/null || true
  ;;
port)
  echo "$PORT"
  ;;
logs)
  tail -f "$LOGS/server.log" "$LOGS/runner.log"
  ;;
esac

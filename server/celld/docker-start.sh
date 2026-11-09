#!/bin/sh
# The container's command (server/Dockerfile.celld). celld takes Worker vars from .dev.vars, not from the
# process environment, so `docker run -e NAME=…` vars are written there, unless one is mounted at
# /app/server/.dev.vars, which then wins as is.
set -eu
cd /app/server
if [ ! -e .dev.vars ]; then
  : > .dev.vars
  for name in GITHUB_ORG GITHUB_ALLOWED_LOGINS RELEASE_CHANNEL PUBLIC_URL DEV_LOGIN SENTRY_DSN SESSION_SECRET \
    GITHUB_APP_ID GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET GITHUB_APP_PRIVATE_KEY GITHUB_WEBHOOK_SECRET; do
    eval "set -- \"\${$name-}\" \"\${$name+set}\""
    [ "$2" = set ] || continue
    # dotenv: quote, escaping backslashes, quotes and newlines (a PEM key is multi-line).
    value=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')
    printf '%s="%s"\n' "$name" "$value" >> .dev.vars
  done
fi
exec celld dev celld.jsonc --host 0.0.0.0 --port "${PORT:-8788}" --no-watch "$@"

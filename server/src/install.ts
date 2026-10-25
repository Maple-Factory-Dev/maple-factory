// GET /install.sh: installs maple-runner from this factory's releases. With an enrollment code it
// also joins the machine and starts the service, so adding a machine is one line:
//   curl -fsSL https://factory.example/install.sh | sh -s -- ABCD-EFGH
// The binary must match the sha256 in the signed manifest (fetched over the same TLS connection
// as this script); from then on the runner verifies each update's signature itself.

export function installScript(origin: string): Response {
  const script = `#!/bin/sh
# Maple Factory runner installer for ${origin}
#   curl -fsSL ${origin}/install.sh | sh -s -- [ENROLLMENT-CODE]
set -eu
ORIGIN="${origin}"
CODE="\${1:-}"
fail() { printf 'maple: %s\\n' "$*" >&2; exit 1; }

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) target=aarch64-apple-darwin ;;
  Darwin/x86_64) target=x86_64-apple-darwin ;;
  Linux/x86_64 | Linux/amd64) target=x86_64-unknown-linux-gnu ;;
  Linux/aarch64 | Linux/arm64) target=aarch64-unknown-linux-gnu ;;
  *) fail "there's no runner build for $(uname -s) $(uname -m)" ;;
esac
command -v curl >/dev/null 2>&1 || fail "curl is needed"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$ORIGIN/releases/maple-runner/latest.json" -o "$tmp/latest.json" || fail "couldn't fetch the release manifest from $ORIGIN"
manifest=$(tr -d ' \\n' < "$tmp/latest.json")
entry=$(printf '%s' "$manifest" | sed -n "s/.*\\"$target\\":{\\([^}]*\\)}.*/\\1/p")
[ -n "$entry" ] || fail "the latest release has no build for $target"
path=$(printf '%s' "$entry" | sed -n 's/.*"path":"\\([^"]*\\)".*/\\1/p')
sum=$(printf '%s' "$entry" | sed -n 's/.*"sha256":"\\([^"]*\\)".*/\\1/p')
version=$(printf '%s' "$manifest" | sed -n 's/^{"version":"\\([^"]*\\)".*/\\1/p')

printf 'Downloading maple-runner %s for %s…\\n' "$version" "$target"
curl -fsSL "$ORIGIN/releases/$path" -o "$tmp/maple-runner" || fail "the download failed"
if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/maple-runner" | cut -d' ' -f1)
else got=$(shasum -a 256 "$tmp/maple-runner" | cut -d' ' -f1); fi
[ "$got" = "$sum" ] || fail "the download doesn't match the release (sha256 $got, expected $sum)"
chmod 755 "$tmp/maple-runner"

bin="$HOME/.local/share/maple/bin"
mkdir -p "$bin" "$HOME/.local/bin"
mv "$tmp/maple-runner" "$bin/maple-runner"
ln -sf "$bin/maple-runner" "$HOME/.local/bin/maple-runner"
printf 'Installed %s\\n' "$bin/maple-runner"

if ! command -v tmux >/dev/null 2>&1; then
  printf '\\nmaple: agents run in tmux, which isn'"'"'t installed. Install it (brew install tmux, or apt install tmux) before sessions start.\\n' >&2
fi

# Linux without systemd (containers, some WSL): no service to install, so it's run by hand.
service=yes
if [ "$(uname -s)" = Linux ] && ! command -v systemctl >/dev/null 2>&1; then service=; fi
start() {
  if [ -n "$service" ]; then "$bin/maple-runner" install
  else printf '\\nThere'"'"'s no systemd here, so start the runner yourself (and keep it running): %s\\n' "$bin/maple-runner"; fi
}

if [ -n "$CODE" ]; then
  "$bin/maple-runner" enroll --url "$ORIGIN" --code "$CODE"
  start
  printf '\\nThis machine is in the factory; it shows up under Machines.\\n'
elif [ -f "$HOME/.config/maple/runner.json" ]; then
  start
else
  printf '\\nNext: get a code from Machines → Add machine, then run\\n  %s enroll --url %s --code XXXX-XXXX && %s install\\n' "$bin/maple-runner" "$ORIGIN" "$bin/maple-runner"
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) printf '(Add ~/.local/bin to your PATH to run maple-runner by name.)\\n' ;; esac
`;
  return new Response(script, { headers: { "content-type": "text/x-shellscript; charset=utf-8", "cache-control": "no-store" } });
}

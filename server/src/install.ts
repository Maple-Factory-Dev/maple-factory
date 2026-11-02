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
  Darwin/x86_64) fail "Intel Macs aren't supported: the runner is built for Apple silicon Macs and Linux" ;;
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

# Checks for git, tmux, Node, the agent CLIs and Playwright, turns lingering on and installs
# Playwright's pieces where that needs no password, and ends with what's still needed. A
# missing tool never fails the install.
doctor() { printf '\\n'; "$bin/maple-runner" doctor --fix || true; }

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
  doctor
elif [ -f "$HOME/.config/maple/runner.json" ]; then
  start
  doctor
else
  printf '\\nNext: get a code from Machines → Add machine, then run\\n  %s enroll --url %s --code XXXX-XXXX && %s install\\n' "$bin/maple-runner" "$ORIGIN" "$bin/maple-runner"
  doctor
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) printf '(Add ~/.local/bin to your PATH to run maple-runner by name.)\\n' ;; esac
`;
  return new Response(script, { headers: { "content-type": "text/x-shellscript; charset=utf-8", "cache-control": "no-store" } });
}

// GET /cloud-init.yaml?code=ABCD-EFGH: user-data to paste when creating a droplet or VM, so the box
// comes up already in the factory. It makes a `maple` user, installs git, tmux, Node LTS and the
// agent CLIs, turns lingering on (so maple's user services run without a login), then runs
// install.sh above as maple with the code. Only the code's shape is checked here; it's put in a
// template and never looked up, so the route is public like install.sh.
const ENROLL_CODE = /^[A-Z0-9]{4}-[A-Z0-9]{4}$/;

export function cloudInitConfig(origin: string, rawCode: string | null): Response {
  const code = (rawCode ?? "").trim().toUpperCase();
  if (!ENROLL_CODE.test(code)) {
    return new Response("Pass an enrollment code: /cloud-init.yaml?code=XXXX-XXXX (get one from Machines → Add machine).\n", {
      status: 400,
      headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
    });
  }
  const yaml = `#cloud-config
# Maple Factory: user-data for a new Linux server (Ubuntu or Debian) that joins ${origin}.
# Paste all of this as user-data when you create the droplet or VM.
#
# - The enrollment code ${code} works once and runs out 15 minutes after it was made,
#   so create the box right away (or get a new code from Machines → Add machine).
# - It makes a user named maple, installs git, tmux, curl, Node LTS and the Claude Code and
#   Codex CLIs, turns lingering on for maple, and installs maple-runner as maple's user service.
#   SSH keys the cloud put on root or the default user are copied to maple.
#   To add your own key too, put it under ssh_authorized_keys below.
# - Progress goes to /var/log/cloud-init-output.log; \`cloud-init status --wait\` waits for it.
# - Agent sign-in is by hand once the box is up (the machine shows under Machines first):
#     ssh maple@<host>, run \`claude\` and sign in with /login
#     Codex: sign in from the machine's page in the app, or run \`codex login --device-auth\`
users:
  - default
  - name: maple
    gecos: Maple Factory runner
    shell: /bin/bash
    lock_passwd: true
    # ssh_authorized_keys:
    #   - ssh-ed25519 AAAA... you@laptop
packages:
  - git
  - tmux
  - curl
  - ca-certificates
package_update: true
runcmd:
  - |
    set -eu
    # SSH keys from root and the default user, so you can ssh in as maple.
    install -d -m 700 -o maple -g maple /home/maple/.ssh
    cat /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null | sort -u > /tmp/maple-keys || true
    cat /tmp/maple-keys >> /home/maple/.ssh/authorized_keys && rm -f /tmp/maple-keys
    chown maple:maple /home/maple/.ssh/authorized_keys && chmod 600 /home/maple/.ssh/authorized_keys
    # Node LTS and the agent CLIs.
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    npm install -g @anthropic-ai/claude-code @openai/codex
    # Lingering, so maple's user services (the runner) start at boot without a login.
    loginctl enable-linger maple
    uid=$(id -u maple)
    systemctl start "user@$uid.service"
    # Install maple-runner as maple, enroll it with the code and start its service.
    sudo -iu maple env XDG_RUNTIME_DIR="/run/user/$uid" sh -c 'curl -fsSL ${origin}/install.sh | sh -s -- ${code}'
`;
  return new Response(yaml, { headers: { "content-type": "text/cloud-config; charset=utf-8", "cache-control": "no-store" } });
}

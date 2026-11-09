#!/bin/sh
# Installs celld (github.com/denoland/celld) at a pinned version, for running maple-server outside
# Cloudflare (server/celld.jsonc). The release publishes no attestation, so each asset's sha256 is kept
# here; bump CELLD_VERSION and all three sums together.
#
#   sh server/celld/install.sh                 # into ${CELLD_BIN_DIR:-$HOME/.local/bin}
#   sh server/celld/install.sh --print-asset   # print the asset this machine would fetch, and stop
#
# CELLD_UNAME_S / CELLD_UNAME_M stand in for `uname -s` / `uname -m` (the tests use them).
set -eu

CELLD_VERSION=0.6.3
SHA_aarch64_apple_darwin=2df6b08369345db8c1f9a5edcf3932cecaa6fb35f4658575a6db17df28c22371
SHA_aarch64_unknown_linux_gnu=6d617cdf9f049e43ca6a4e37c4cce5d8e35395c8e86b371c984d32ba7d803bf5
SHA_x86_64_unknown_linux_gnu=5084a083472cf036551a7eac63fa24d22bb9a56323c517f63205724c12783047

os=${CELLD_UNAME_S:-$(uname -s)}
arch=${CELLD_UNAME_M:-$(uname -m)}
case "$os/$arch" in
  Darwin/arm64 | Darwin/aarch64) target=aarch64-apple-darwin; sha=$SHA_aarch64_apple_darwin ;;
  Linux/aarch64 | Linux/arm64) target=aarch64-unknown-linux-gnu; sha=$SHA_aarch64_unknown_linux_gnu ;;
  Linux/x86_64 | Linux/amd64) target=x86_64-unknown-linux-gnu; sha=$SHA_x86_64_unknown_linux_gnu ;;
  *)
    echo "celld $CELLD_VERSION has no build for $os/$arch (it ships for macOS arm64, Linux arm64 and Linux x86_64)." >&2
    exit 1 ;;
esac
asset="celld-$target.gz"

if [ "${1:-}" = "--print-asset" ]; then
  echo "$asset"
  exit 0
fi

bin_dir=${CELLD_BIN_DIR:-$HOME/.local/bin}
bin="$bin_dir/celld"

if [ -x "$bin" ] && "$bin" --version 2>/dev/null | grep -q "^celld $CELLD_VERSION\$"; then
  echo "celld $CELLD_VERSION is already at $bin"
else
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  url="https://github.com/denoland/celld/releases/download/v$CELLD_VERSION/$asset"
  echo "Downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp/$asset" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp/$asset" "$url"
  else
    echo "Needs curl or wget to download celld." >&2
    exit 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$tmp/$asset" | cut -d' ' -f1)
  else
    got=$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)
  fi
  if [ "$got" != "$sha" ]; then
    echo "Checksum mismatch for $asset: expected $sha, got $got. Not installing." >&2
    exit 1
  fi
  echo "Checksum OK ($sha)"
  gunzip "$tmp/$asset"
  mkdir -p "$bin_dir"
  chmod +x "$tmp/celld-$target"
  mv "$tmp/celld-$target" "$bin"
  echo "Installed celld $CELLD_VERSION at $bin"
  case ":$PATH:" in *":$bin_dir:"*) ;; *) echo "Note: $bin_dir isn't on PATH." ;; esac
fi

# celld bundles the Worker with esbuild: the workspace's copy (from wrangler) after `npm ci`.
here=$(cd "$(dirname "$0")" && pwd)
esbuild="$here/../../node_modules/.bin/esbuild"
if [ -n "${CELLD_ESBUILD:-}" ] && [ -x "$CELLD_ESBUILD" ]; then
  :
elif [ -x "$esbuild" ]; then
  :
elif command -v esbuild >/dev/null 2>&1; then
  :
else
  echo "esbuild is missing: run \`npm ci\` at the repo root (celld uses node_modules/.bin/esbuild)." >&2
  exit 1
fi

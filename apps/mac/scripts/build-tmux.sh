#!/bin/sh
# Builds a universal (arm64 + x86_64) tmux the app can carry, so a Mac doesn't need Homebrew to run
# agents: libevent is linked in statically, ncurses comes from macOS. Cached in build/helpers/.
#   apps/mac/scripts/build-tmux.sh        → apps/mac/build/helpers/tmux
set -eu
unset CDPATH

TMUX_VERSION=3.5a
LIBEVENT_VERSION=2.1.12-stable
here="$(dirname "$(dirname "$(realpath "$0")")")"
out="$here/build/helpers"
[ -x "$out/tmux" ] && "$out/tmux" -V | grep -q "$TMUX_VERSION" && { echo "$out/tmux"; exit 0; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"
export CFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -O2"
export LDFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=13.0"

cd "$work"
curl -fsSL "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz" | tar xz
(cd "libevent-$LIBEVENT_VERSION" && ./configure --prefix="$prefix" --disable-shared --enable-static --disable-openssl --disable-samples --disable-libevent-regress >/dev/null && make -j8 >/dev/null && make install >/dev/null)

curl -fsSL "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz" | tar xz
cd "tmux-$TMUX_VERSION"
# macOS's ncurses; pkg-config would find Homebrew's otherwise.
PKG_CONFIG=/usr/bin/false LIBEVENT_CFLAGS="-I$prefix/include" LIBEVENT_LIBS="$prefix/lib/libevent_core.a" \
  LIBNCURSES_CFLAGS="" LIBNCURSES_LIBS="-lncurses" \
  ./configure --disable-utf8proc >/dev/null
make -j8 >/dev/null

mkdir -p "$out"
cp tmux "$out/tmux"
if otool -L "$out/tmux" | grep -q "/opt/homebrew\|/usr/local"; then echo "tmux still links outside macOS:" >&2; otool -L "$out/tmux" >&2; exit 1; fi
echo "$out/tmux"

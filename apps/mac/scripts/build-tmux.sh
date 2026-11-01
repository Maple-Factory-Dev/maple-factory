#!/bin/sh
# Builds a universal (arm64 + x86_64) tmux the app can carry, so a Mac doesn't need Homebrew to run
# agents: libevent is linked in statically, ncurses comes from macOS.
#   apps/mac/scripts/build-tmux.sh        → apps/mac/build/helpers/tmux   (the path is the only stdout)
#
# Both tarballs are pinned by SHA-256 and checked before anything is extracted. The binary is cached
# in build/helpers/ next to tmux.stamp, which records every build input; any change rebuilds.
# Verified tarballs are kept in build/cache/ and re-checked on every use.
set -eu
unset CDPATH

# Bump by hand for any recipe change the variables below don't capture (the env passed to tmux's
# configure, the build steps themselves).
RECIPE=1

# Versions and hashes can be overridden from the environment (to try an upgrade, or to watch a bad
# hash fail), but a new version needs its hash pinned here.
TMUX_VERSION="${TMUX_VERSION:-3.5a}"
# sha256 of https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz (tmux publishes no
# signature; pinned from the GitHub release asset, matches Homebrew's and MacPorts' pin).
TMUX_SHA256="${TMUX_SHA256:-16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951}"
LIBEVENT_VERSION="${LIBEVENT_VERSION:-2.1.12-stable}"
# sha256 of https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz
# whose .asc verified with gpg as a good signature from Azat Khuzhin (libevent maintainer),
# key 9E3AC83A27974B84D1B3401DB86086848EF8686D, when this hash was pinned.
LIBEVENT_SHA256="${LIBEVENT_SHA256:-92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb}"

ARCHS="arm64 x86_64"
MACOS_MIN=13.0
arch_flags="$(for a in $ARCHS; do printf -- '-arch %s ' "$a"; done)"
CFLAGS="${arch_flags}-mmacosx-version-min=$MACOS_MIN -O2"
LDFLAGS="${arch_flags}-mmacosx-version-min=$MACOS_MIN"
# ac_cv_func_pipe2=no: newer SDKs declare pipe2 (macOS 27+), so libevent would weak-import a symbol
# that's NULL on the macOS 13 we support. The weak-import check below catches any others.
LIBEVENT_CONFIGURE="--disable-shared --enable-static --disable-openssl --disable-samples --disable-libevent-regress ac_cv_func_pipe2=no"
TMUX_CONFIGURE="--disable-utf8proc"

here="$(dirname "$(dirname "$(realpath "$0")")")"
out="$here/build/helpers"
cache="$here/build/cache"
stamp="$out/tmux.stamp"

die() { echo "build-tmux: $*" >&2; exit 1; }

# Everything that decides what the binary looks like. The stamp holds this text and its hash.
inputs="RECIPE=$RECIPE
TMUX_VERSION=$TMUX_VERSION
TMUX_SHA256=$TMUX_SHA256
LIBEVENT_VERSION=$LIBEVENT_VERSION
LIBEVENT_SHA256=$LIBEVENT_SHA256
ARCHS=$ARCHS
MACOS_MIN=$MACOS_MIN
CFLAGS=$CFLAGS
LDFLAGS=$LDFLAGS
LIBEVENT_CONFIGURE=$LIBEVENT_CONFIGURE
TMUX_CONFIGURE=$TMUX_CONFIGURE"
key="$(printf '%s\n' "$inputs" | shasum -a 256 | cut -c1-64)"
stamp_text="$inputs
KEY=$key"

if [ -x "$out/tmux" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$stamp_text" ]; then
  echo "tmux: cached (key ${key%"${key#????????????}"})" >&2
  echo "$out/tmux"
  exit 0
fi
if [ -f "$stamp" ]; then
  changed="$(printf '%s\n' "$inputs" | grep -vxF -f "$stamp" | cut -d= -f1 | paste -sd, - || true)"
  echo "tmux: building (key changed: ${changed:-binary missing})" >&2
else
  echo "tmux: building (key changed: no stamp)" >&2
fi

# fetch URL FILE SHA256: leaves a verified $cache/FILE, or fails before anything is extracted.
fetch() {
  f="$cache/$2"
  # A cached file that doesn't match is left alone: it's replaced only by a download that does.
  [ -f "$f" ] && echo "$3  $f" | shasum -a 256 -c -s && return 0
  mkdir -p "$cache"
  curl -fsSL "$1" -o "$f.part" || die "couldn't download $1"
  if ! echo "$3  $f.part" | shasum -a 256 -c -s; then
    actual="$(shasum -a 256 "$f.part" | cut -c1-64)"
    rm -f "$f.part"
    die "checksum mismatch for $2
  expected $3
  actual   $actual"
  fi
  mv "$f.part" "$f"
}

fetch "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz" \
  "libevent-$LIBEVENT_VERSION.tar.gz" "$LIBEVENT_SHA256"
fetch "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz" \
  "tmux-$TMUX_VERSION.tar.gz" "$TMUX_SHA256"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"
jobs="$(sysctl -n hw.ncpu)"
log="$work/build.log"
export CFLAGS LDFLAGS
# Compiler output goes to a log, shown only when a step fails.
step() { "$@" >>"$log" 2>&1 || { tail -40 "$log" >&2; die "failed: $*"; }; }

cd "$work"
tar xzf "$cache/libevent-$LIBEVENT_VERSION.tar.gz"
cd "libevent-$LIBEVENT_VERSION"
# shellcheck disable=SC2086 # the configure args are word lists on purpose
step ./configure --prefix="$prefix" $LIBEVENT_CONFIGURE
step make -j"$jobs"
step make install

cd "$work"
tar xzf "$cache/tmux-$TMUX_VERSION.tar.gz"
cd "tmux-$TMUX_VERSION"
# macOS's ncurses; pkg-config would find Homebrew's otherwise.
export PKG_CONFIG=/usr/bin/false LIBEVENT_CFLAGS="-I$prefix/include" LIBEVENT_LIBS="$prefix/lib/libevent_core.a" \
  LIBNCURSES_CFLAGS="" LIBNCURSES_LIBS="-lncurses"
# shellcheck disable=SC2086
step ./configure $TMUX_CONFIGURE
step make -j"$jobs"
bin="$work/tmux-$TMUX_VERSION/tmux"

# Check what ships before it replaces anything.
want_archs="$(printf '%s\n' $ARCHS | sort | paste -sd' ' -)"
got_archs="$(lipo -archs "$bin" | tr ' ' '\n' | sort | paste -sd' ' -)"
[ "$got_archs" = "$want_archs" ] || die "tmux has archs '$got_archs', want '$want_archs'"
[ "$("$bin" -V)" = "tmux $TMUX_VERSION" ] || die "tmux -V says '$("$bin" -V)', want 'tmux $TMUX_VERSION'"
for a in $ARCHS; do
  minos="$(vtool -arch "$a" -show-build "$bin" | awk '$1 == "minos" { print $2 }')"
  [ "$minos" = "$MACOS_MIN" ] || die "tmux ($a) has minos '$minos', want $MACOS_MIN"
done
if otool -L "$bin" | grep -q "/opt/homebrew\|/usr/local\|libevent"; then
  otool -L "$bin" >&2
  die "tmux links outside macOS (or to a libevent dylib)"
fi
# A weak import is an API newer than MACOS_MIN that the SDK let through; it'd be NULL on older macOS.
if nm -m "$bin" | grep "(undefined) weak" >&2; then die "tmux weak-imports symbols missing on macOS $MACOS_MIN"; fi

mkdir -p "$out"
rm -f "$stamp"
cp "$bin" "$out/tmux.tmp"
mv "$out/tmux.tmp" "$out/tmux"
printf '%s\n' "$stamp_text" > "$stamp"
echo "tmux: built (key ${key%"${key#????????????}"})" >&2
echo "$out/tmux"

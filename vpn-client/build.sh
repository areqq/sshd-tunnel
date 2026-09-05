#!/bin/sh
# Build a static DSVPN client for one architecture.
#
#   vpn-client/build.sh <arch>
#
# arch: x86_64 | i686 | armv7 | armv5 | aarch64 | mips | mipsel
#
# The point of shipping this at all: the OpenVPN mode needs an openvpn binary
# on the device, and plenty of routers do not have one. DSVPN is ~1500 lines
# of C with its own crypto (charm.c, Xoodoo-based) and no external
# dependencies, so it cross-compiles static into ~100-150 kB — small enough to
# hand to a device that has nothing.
#
# Everything is fetched on demand (Bootlin musl toolchain + DSVPN source), so
# a clean machine needs only curl, tar, make and a C compiler for the host.
#
# Environment:
#   DSVPN_REF   git ref/tag of the source  (default: master)
#   TC_VER      Bootlin toolchain release  (default: 2025.08-1)
#   OUT_DIR     where the tarball is written (default: vpn-client/out)

set -eu

ARCH="${1:?usage: build.sh <x86_64|i686|armv7|armv5|aarch64|mips|mipsel>}"
DSVPN_REF="${DSVPN_REF:-master}"
TC_VER="${TC_VER:-2025.08-1}"

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$HERE/out}"
WORK="$HERE/.build/$ARCH"

DSVPN_TARBALL="dsvpn-$DSVPN_REF.tar.gz"
DSVPN_URL="https://github.com/jedisct1/dsvpn/archive/refs/heads/$DSVPN_REF.tar.gz"
TC_BASE="https://toolchains.bootlin.com/downloads/releases/toolchains"

log() { printf '==> %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

# Same arch table as client/build.sh: soft-float on MIPS and armv5 because
# that is what those devices ship, and the float ABI has to match the
# toolchain's or the binary dies with an illegal instruction on real silicon.
case "$ARCH" in
	x86_64)  TC_SLUG='x86-64';       ACFLAGS='' ;;
	i686)    TC_SLUG='x86-i686';     ACFLAGS='' ;;
	armv7)   TC_SLUG='armv7-eabihf'; ACFLAGS='-mcpu=cortex-a7 -mfpu=neon-vfpv4' ;;
	armv5)   TC_SLUG='armv5-eabi';   ACFLAGS='-msoft-float' ;;
	aarch64) TC_SLUG='aarch64';      ACFLAGS='' ;;
	mips)    TC_SLUG='mips32';       ACFLAGS='-msoft-float' ;;
	mipsel)  TC_SLUG='mips32el';     ACFLAGS='-msoft-float' ;;
	*) die "unknown arch: $ARCH" ;;
esac

TC_NAME="$TC_SLUG--musl--stable-$TC_VER"
TC_DIR="$HERE/toolchain/$TC_NAME"

for tool in curl tar make; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done

# ---------------------------------------------------------------- toolchain
# Shared with client/: one download serves both builds.
if [ ! -d "$TC_DIR" ] && [ -d "$HERE/../client/toolchain/$TC_NAME" ]; then
	mkdir -p "$HERE/toolchain"
	ln -sfn "$(CDPATH='' cd -- "$HERE/../client/toolchain/$TC_NAME" && pwd)" "$TC_DIR"
fi
if [ ! -d "$TC_DIR" ]; then
	log "fetching toolchain $TC_NAME"
	mkdir -p "$HERE/toolchain"
	curl -fsSL -o "$HERE/toolchain/$TC_NAME.tar.xz" \
		"$TC_BASE/$TC_SLUG/tarballs/$TC_NAME.tar.xz" || die 'toolchain download failed'
	tar xf "$HERE/toolchain/$TC_NAME.tar.xz" -C "$HERE/toolchain"
	rm -f "$HERE/toolchain/$TC_NAME.tar.xz"
fi

CC="$(ls "$TC_DIR/bin/"*-gcc 2>/dev/null | grep buildroot | head -1)"
[ -n "$CC" ] || CC="$(ls "$TC_DIR/bin/"*-linux*-gcc 2>/dev/null | head -1)"
[ -n "$CC" ] || die "no gcc found in $TC_DIR/bin"
STRIP="${CC%-gcc}-strip"

# ------------------------------------------------------------------ source
mkdir -p "$HERE/src-cache"
if [ ! -f "$HERE/src-cache/$DSVPN_TARBALL" ]; then
	log "fetching $DSVPN_TARBALL"
	curl -fsSL -o "$HERE/src-cache/$DSVPN_TARBALL" "$DSVPN_URL" || die 'dsvpn source download failed'
fi

rm -rf "$WORK"
mkdir -p "$WORK/src"
tar xzf "$HERE/src-cache/$DSVPN_TARBALL" -C "$WORK/src" --strip-components=1
[ -f "$WORK/src/Makefile" ] || die 'unexpected dsvpn source layout'

# Upstream reconfigures the whole machine on connect (sysctl, iptables,
# default-route hijack). Stripped out: this project wants a plain
# point-to-point link, and half those commands do not exist on the devices —
# where a single failing one aborts dsvpn outright.
log 'applying the no-system-changes patch'
patch -p1 -d "$WORK/src" < "$HERE/patches/no-system-changes.patch" >/dev/null \
	|| die 'patch failed to apply'

# ------------------------------------------------------------------- build
# CFLAGS must be set explicitly: left empty, dsvpn's Makefile probes for
# -march=native/-mtune=native, which is meaningless (and wrong) when
# cross-compiling.
#
# The Makefile also ends with a bare `strip`, which on a cross build would run
# the host's and refuse a foreign binary — a shim directory puts the
# toolchain's strip under that name, first on PATH.
mkdir -p "$WORK/shim"
ln -sf "$STRIP" "$WORK/shim/strip"

# NO_DEFAULT_ROUTES is upstream's own switch for "do not touch the routing
# table". The patch already removed those commands; the define also drops the
# leftover re-detection of the gateway on every reconnect, which would shell
# out to `ip route show default` for a value nothing reads.
log "building dsvpn for $ARCH"
( cd "$WORK/src" && PATH="$WORK/shim:$PATH" make \
	CC="$CC" CFLAGS="-Os -static -Wall -DNO_DEFAULT_ROUTES $ACFLAGS" \
	>"$WORK/make.log" 2>&1 ) \
	|| { tail -20 "$WORK/make.log" >&2; die 'build failed'; }

BIN="$WORK/src/dsvpn"
[ -f "$BIN" ] || die 'dsvpn binary was not produced'

# A dynamically linked binary here would be useless on a device with a
# different libc, and the failure would only show up on the device.
if command -v file >/dev/null 2>&1; then
	file "$BIN" | grep -q 'statically linked' || die 'the binary is not static'
fi

# ------------------------------------------------------------------ package
mkdir -p "$OUT_DIR"
STAGE="$WORK/pkg/dsvpn-$ARCH"
mkdir -p "$STAGE"
cp "$BIN" "$STAGE/dsvpn"
chmod 755 "$STAGE/dsvpn"
cp "$WORK/src/README.md" "$STAGE/DSVPN-README.md" 2>/dev/null || true
cp "$WORK/src/LICENSE" "$STAGE/DSVPN-LICENSE" 2>/dev/null || true

TARBALL="$OUT_DIR/dsvpn-$ARCH.tgz"
rm -f "$TARBALL"
tar czf "$TARBALL" -C "$WORK/pkg" "dsvpn-$ARCH"
( cd "$OUT_DIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

log "done: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
printf '    %s bytes\n' "$(wc -c <"$STAGE/dsvpn")"

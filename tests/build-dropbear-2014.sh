#!/bin/sh
# Build a genuine Dropbear 2014 client, used by the test suite to prove the
# server is reachable from a client of that vintage rather than merely
# advertising the right algorithm names.
#
#   tests/build-dropbear-2014.sh [output-dir]
#
# Two adjustments are needed to compile 2014-era C with a current toolchain:
#   -std=gnu89   because C23 (the default in GCC 15) treats `int (*f)()` as a
#                prototype taking no arguments, which breaks atomicio.c;
#   linux-headers on Alpine, which does not ship <linux/types.h> by default.
#
# Environment:
#   DROPBEAR_URL   override the source URL (e.g. a local mirror)

set -eu

VERSION='2014.63'
SHA256='595992de432ba586a0e7e191bbb1ad587727678bb3e345b018c395b8c55b57ae'
URL="${DROPBEAR_URL:-https://matt.ucc.asn.au/dropbear/releases/dropbear-$VERSION.tar.bz2}"

OUT_DIR="${1:-dist/dropbear-$VERSION}"
BINARIES='dbclient dropbearkey dropbearconvert'

log() { printf '==> %s\n' "$*"; }
die() { printf 'build-dropbear-2014: %s\n' "$*" >&2; exit 1; }

OUT_DIR="$(mkdir -p "$OUT_DIR" && CDPATH='' cd -- "$OUT_DIR" && pwd)"

if [ -x "$OUT_DIR/dbclient" ]; then
	log "already built: $OUT_DIR/dbclient"
	"$OUT_DIR/dbclient" -h 2>&1 | head -1
	exit 0
fi

for tool in curl tar make gcc; do
	command -v "$tool" >/dev/null 2>&1 || die "missing build dependency: $tool"
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM HUP

log "downloading dropbear $VERSION"
curl -fsSL -o "$WORKDIR/src.tar.bz2" "$URL" || die "cannot download $URL"

ACTUAL="$(sha256sum "$WORKDIR/src.tar.bz2" | cut -d' ' -f1)"
[ "$ACTUAL" = "$SHA256" ] || die "checksum mismatch: expected $SHA256, got $ACTUAL"
log 'checksum verified'

tar xjf "$WORKDIR/src.tar.bz2" -C "$WORKDIR"
SRC="$WORKDIR/dropbear-$VERSION"
[ -d "$SRC" ] || die 'unexpected source layout'

log 'configuring'
( cd "$SRC" && ./configure \
	--disable-zlib --disable-utmp --disable-utmpx --disable-wtmp --disable-lastlog \
	CFLAGS='-O2 -std=gnu89 -Wno-error -Wno-implicit-function-declaration -Wno-int-conversion -Wno-deprecated-declarations -fcommon' \
	>"$WORKDIR/configure.log" 2>&1 ) || {
		tail -30 "$WORKDIR/configure.log" >&2
		die 'configure failed'
	}

log 'compiling'
( cd "$SRC" && make PROGRAMS="$BINARIES" -j"$(nproc 2>/dev/null || echo 2)" \
	>"$WORKDIR/make.log" 2>&1 ) || {
		grep -E 'error:|Error [0-9]|undefined reference' "$WORKDIR/make.log" | head -20 >&2
		die 'compilation failed'
	}

for binary in $BINARIES; do
	[ -x "$SRC/$binary" ] || die "$binary was not produced"
	cp "$SRC/$binary" "$OUT_DIR/$binary"
done

log "built into $OUT_DIR"
"$OUT_DIR/dbclient" -h 2>&1 | head -1

#!/bin/sh
# Build a static, multi-call Dropbear (dbclient + server + dropbearkey +
# dropbearconvert) for one architecture, with runtime-patchable credential
# slots baked in. The produced binary needs no libraries and no toolchain to
# refresh its keys — see patch-cred and the slot markers.
#
#   client/build.sh <arch>
#
# arch: x86_64 | i686 | armv7 | armv5 | aarch64 | mips | mipsel
#
# Everything is fetched on demand (Bootlin musl toolchain + Dropbear source),
# so a clean machine needs only curl, tar, make and a C compiler for the host.
#
# Environment:
#   DB_VER      Dropbear version           (default: 2026.94)
#   TC_VER      Bootlin toolchain release  (default: 2025.08-1)
#   OUT_DIR     where the tarball is written (default: client/out)
#   JOBS        parallel make jobs         (default: nproc)

set -eu

ARCH="${1:?usage: build.sh <x86_64|i686|armv7|armv5|aarch64|mips|mipsel>}"
DB_VER="${DB_VER:-2026.94}"
TC_VER="${TC_VER:-2025.08-1}"

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$HERE/out}"
WORK="$HERE/.build/$ARCH"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

DB_TARBALL="dropbear-$DB_VER.tar.bz2"
DB_URL="https://matt.ucc.asn.au/dropbear/releases/$DB_TARBALL"
TC_BASE="https://toolchains.bootlin.com/downloads/releases/toolchains"

log() { printf '==> %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

# arch -> Bootlin toolchain slug + arch-specific CFLAGS. Soft-float on MIPS and
# armv5 because that is what the overwhelming majority of those devices ship.
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

for tool in curl tar make sed awk; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done

# ---------------------------------------------------------------- toolchain
if [ ! -d "$TC_DIR" ]; then
	log "fetching toolchain $TC_NAME"
	mkdir -p "$HERE/toolchain"
	curl -fsSL -o "$HERE/toolchain/$TC_NAME.tar.xz" \
		"$TC_BASE/$TC_SLUG/tarballs/$TC_NAME.tar.xz" || die 'toolchain download failed'
	tar xf "$HERE/toolchain/$TC_NAME.tar.xz" -C "$HERE/toolchain"
	rm -f "$HERE/toolchain/$TC_NAME.tar.xz"
fi

# The Bootlin bin dir holds "<triple>-gcc"; pick the buildroot one.
CC="$(ls "$TC_DIR/bin/"*-gcc 2>/dev/null | grep buildroot | head -1)"
[ -n "$CC" ] || CC="$(ls "$TC_DIR/bin/"*-linux*-gcc 2>/dev/null | head -1)"
[ -n "$CC" ] || die "no gcc found in $TC_DIR/bin"
STRIP="${CC%-gcc}-strip"
HOST_TRIPLE="$(basename "${CC%-gcc}")"
export PATH="$TC_DIR/bin:$PATH"
export CC

# ------------------------------------------------------------------ source
mkdir -p "$HERE/src-cache"
if [ ! -f "$HERE/src-cache/$DB_TARBALL" ]; then
	log "fetching $DB_TARBALL"
	curl -fsSL -o "$HERE/src-cache/$DB_TARBALL" "$DB_URL" || die 'dropbear source download failed'
fi

rm -rf "$WORK"
mkdir -p "$WORK"
tar xf "$HERE/src-cache/$DB_TARBALL" -C "$WORK"
SRC="$WORK/dropbear-$DB_VER"
[ -d "$SRC" ] || die 'unexpected source layout'

# --------------------------------------------------- slots + config + patch
log 'applying credential-slot patch and config'
patch -p1 -d "$SRC" < "$HERE/patches/embedded-slots.patch" >/dev/null || die 'patch failed to apply'
cp -f "$HERE/localoptions.h" "$SRC/localoptions.h"

# Optional SFTP subsystem in the embedded server (WITH_SFTP=1). Off by default,
# so the proven core build is untouched. The sftp-server binary itself is built
# separately by build-sftp.sh and staged at SFTPSERVER_PATH on the device.
if [ "${WITH_SFTP:-0}" = '1' ]; then
	log 'enabling SFTP server subsystem (WITH_SFTP=1)'
	{
		echo '#undef DROPBEAR_SFTPSERVER'
		echo '#define DROPBEAR_SFTPSERVER 1'
		echo '#undef SFTPSERVER_PATH'
		echo '#define SFTPSERVER_PATH "/tmp/sftp-server"'
	} >> "$SRC/localoptions.h"
fi

"$HERE/gen_cred_slots.sh" "$SRC" >/dev/null || die 'slot generation failed'

# ------------------------------------------------------------------- build
CFLAGS="-Os -ffunction-sections -fdata-sections -fomit-frame-pointer $ACFLAGS"
LDFLAGS="-static -Wl,--gc-sections"

log "building dropbearmulti for $ARCH ($HOST_TRIPLE)"
( cd "$SRC" && ./configure --host="$HOST_TRIPLE" \
	CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
	--enable-static --disable-zlib --disable-pam --disable-shadow \
	--disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
	--disable-loginfunc --disable-pututline --disable-pututxline --disable-openpty \
	>"$WORK/configure.log" 2>&1 ) || { tail -20 "$WORK/configure.log" >&2; die 'configure failed'; }

( cd "$SRC" && make -j"$JOBS" \
	PROGRAMS="dbclient dropbear dropbearkey dropbearconvert" MULTI=1 \
	>"$WORK/make.log" 2>&1 ) || { grep -iE 'error:|undefined' "$WORK/make.log" | head -20 >&2; die 'build failed'; }

[ -f "$SRC/dropbearmulti" ] || die 'dropbearmulti was not produced'
"$STRIP" -s "$SRC/dropbearmulti"

# ---------------------------------------------------------------- verify
for m in id hk ak; do
	grep -q "@@DBCRED:$m:B@@" "$SRC/dropbearmulti" || die "slot marker $m missing from the binary"
done
log 'all three credential slots present'

# ------------------------------------------------------------------ package
mkdir -p "$OUT_DIR"
STAGE="$WORK/pkg/dropbear-tunnel-$ARCH"
mkdir -p "$STAGE"
cp "$SRC/dropbearmulti" "$STAGE/dropbearmulti"
cp "$HERE/patch-cred" "$STAGE/patch-cred"
cp "$HERE/bootstrap.sh" "$STAGE/bootstrap.sh" 2>/dev/null || true
cp "$HERE/README.md" "$STAGE/README.md" 2>/dev/null || true
chmod 755 "$STAGE/dropbearmulti" "$STAGE/patch-cred"
[ -f "$STAGE/bootstrap.sh" ] && chmod 755 "$STAGE/bootstrap.sh"

# Bundle the static SFTP binaries if they were built for this arch.
if [ "${WITH_SFTP:-0}" = '1' ]; then
	log 'building and bundling static SFTP (sftp + sftp-server)'
	"$HERE/build-sftp.sh" "$ARCH" || die 'SFTP build failed (WITH_SFTP=1)'
	cp "$HERE/out/sftp-$ARCH/sftp-server" "$STAGE/sftp-server"
	cp "$HERE/out/sftp-$ARCH/sftp" "$STAGE/sftp"
	chmod 755 "$STAGE/sftp-server" "$STAGE/sftp"
	# dropbearmulti dispatches on argv[0] or (run bare) on argv[1]; `sftp -S`
	# execs the transport directly with ssh-style args in argv[1..], so it
	# needs a binary/symlink literally named 'dbclient' to dispatch correctly.
	ln -sf dropbearmulti "$STAGE/dbclient"
fi

TARBALL="$OUT_DIR/dropbear-tunnel-$ARCH.tgz"
rm -f "$TARBALL"
tar czf "$TARBALL" -C "$WORK/pkg" "dropbear-tunnel-$ARCH"
( cd "$OUT_DIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

log "done: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
"$STRIP" --version >/dev/null 2>&1 || true
printf '    %s\n' "$(cd "$SRC" && ls -l dropbearmulti | awk '{print $5" bytes"}')"

#!/bin/sh
# Build static OpenSSH `sftp` (client) and `sftp-server` for one architecture,
# to ship alongside dropbearmulti. Dropbear has no SFTP of its own: its server
# only offers the subsystem by exec'ing an external sftp-server, and it has no
# sftp client at all. These two binaries fill both gaps.
#
#   client/build-sftp.sh <arch>
#
# On the device:
#   - sftp-server is what the embedded Dropbear server execs for the SFTP
#     subsystem (see SFTPSERVER_PATH, set when build.sh runs with WITH_SFTP=1);
#   - sftp -S ./dropbearmulti  routes an SFTP client session over dbclient.
#
# STATUS: UNVERIFIED. This cross-build has not yet been run green in CI; it is
# intentionally kept out of the default matrix so it cannot break the core
# dropbearmulti build. Enable it with WITH_SFTP=1 once it is proven on an arch.
#
# Environment:
#   OPENSSH_VER   OpenSSH portable version   (default: 9.9p2)
#   OUT_DIR       where binaries are placed  (default: client/out/sftp-<arch>)

set -eu

ARCH="${1:?usage: build-sftp.sh <arch>}"
OPENSSH_VER="${OPENSSH_VER:-9.9p2}"
TC_VER="${TC_VER:-2025.08-1}"

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$HERE/out/sftp-$ARCH}"
WORK="$HERE/.build/sftp-$ARCH"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

OSSH_TARBALL="openssh-$OPENSSH_VER.tar.gz"
OSSH_URL="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/$OSSH_TARBALL"

log() { printf '==> %s\n' "$*"; }
die() { printf 'build-sftp: %s\n' "$*" >&2; exit 1; }

case "$ARCH" in
	x86_64)  TC_SLUG='x86-64' ;;
	i686)    TC_SLUG='x86-i686' ;;
	armv7)   TC_SLUG='armv7-eabihf' ;;
	armv5)   TC_SLUG='armv5-eabi' ;;
	aarch64) TC_SLUG='aarch64' ;;
	mips)    TC_SLUG='mips32' ;;
	mipsel)  TC_SLUG='mips32el' ;;
	*) die "unknown arch: $ARCH" ;;
esac

TC_NAME="$TC_SLUG--musl--stable-$TC_VER"
TC_DIR="$HERE/toolchain/$TC_NAME"
[ -d "$TC_DIR" ] || die "toolchain $TC_NAME not present — run build.sh $ARCH first"

CC="$(ls "$TC_DIR/bin/"*-gcc 2>/dev/null | grep buildroot | head -1)"
[ -n "$CC" ] || CC="$(ls "$TC_DIR/bin/"*-linux*-gcc 2>/dev/null | head -1)"
[ -n "$CC" ] || die "no gcc in $TC_DIR/bin"
STRIP="${CC%-gcc}-strip"
HOST_TRIPLE="$(basename "${CC%-gcc}")"
export PATH="$TC_DIR/bin:$PATH"

mkdir -p "$HERE/src-cache"
[ -f "$HERE/src-cache/$OSSH_TARBALL" ] || {
	log "fetching $OSSH_TARBALL"
	curl -fsSL -o "$HERE/src-cache/$OSSH_TARBALL" "$OSSH_URL" || die 'openssh download failed'
}

rm -rf "$WORK"; mkdir -p "$WORK"
tar xf "$HERE/src-cache/$OSSH_TARBALL" -C "$WORK"
SRC="$WORK/openssh-$OPENSSH_VER"
[ -d "$SRC" ] || die 'unexpected openssh source layout'

# sftp and sftp-server do no asymmetric crypto themselves, so the build drops
# OpenSSL and zlib to stay small and fully static. Cross-compile cache vars tell
# configure the answers it cannot probe by running target binaries.
log "configuring OpenSSH $OPENSSH_VER for $ARCH ($HOST_TRIPLE)"
( cd "$SRC" && ./configure --host="$HOST_TRIPLE" CC="$CC" \
	--without-openssl --without-zlib --without-pam \
	--without-selinux --without-kerberos5 --disable-utmp --disable-wtmp \
	CFLAGS="-Os -ffunction-sections -fdata-sections" \
	LDFLAGS="-static -Wl,--gc-sections" \
	ac_cv_func_setresuid=yes ac_cv_func_setresgid=yes \
	>"$WORK/configure.log" 2>&1 ) || { tail -25 "$WORK/configure.log" >&2; die 'configure failed'; }

log 'building sftp-server and sftp'
( cd "$SRC" && make -j"$JOBS" sftp-server sftp >"$WORK/make.log" 2>&1 ) \
	|| { grep -iE 'error:|undefined' "$WORK/make.log" | head -20 >&2; die 'build failed'; }

mkdir -p "$OUT_DIR"
for b in sftp-server sftp; do
	[ -f "$SRC/$b" ] || die "$b was not produced"
	"$STRIP" -s "$SRC/$b"
	cp "$SRC/$b" "$OUT_DIR/$b"
done
log "done: $OUT_DIR (sftp-server, sftp)"

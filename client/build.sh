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

# Optional SFTP, merged into the same binary (WITH_SFTP=1). Off by default, so
# the proven core build is untouched. OpenSSH's sftp/sftp-server objects are
# built and linked straight into dropbearmulti as two more multi-call applets
# ("sftp", "sftp-server") — see the merge step after the dropbear build below.
if [ "${WITH_SFTP:-0}" = '1' ]; then
	log 'enabling SFTP server subsystem (WITH_SFTP=1)'
	{
		echo '#undef DROPBEAR_SFTPSERVER'
		echo '#define DROPBEAR_SFTPSERVER 1'
		echo '#undef SFTPSERVER_PATH'
		echo '#define SFTPSERVER_PATH "/tmp/sftp-server"'
	} >> "$SRC/localoptions.h"
	patch -p1 -d "$SRC" < "$HERE/patches/embedded-sftp-dispatch.patch" >/dev/null \
		|| die 'sftp dispatch patch failed to apply'
fi

"$HERE/gen_cred_slots.sh" "$SRC" >/dev/null || die 'slot generation failed'

# ------------------------------------------------------------------- build
# -flto was tried here and reverted: dropbear's bundled libtomcrypt.a /
# libtommath.a are plain (non-LTO) archives placed once at the end of the
# link line, and gcc's LTO recompilation discovers its need for their
# symbols too late for that single archive scan — every arch failed with
# "undefined reference" into an "<artificial>" (LTO-merged) unit. The
# standard fix (wrap those archives in -Wl,--start-group/--end-group) needs
# a patch to dropbear's own Makefile.in, not just CFLAGS/LDFLAGS here, so
# it's a separate, bigger change if it's ever worth doing.
# -fno-(asynchronous-)unwind-tables was also tried (real ~40-100 KB savings
# on x86_64/i686/aarch64, a byte-identical no-op on armv7/armv5/mips/mipsel)
# and reverted: on the real GitHub Actions runner (never reproduced locally),
# a WITH_SFTP=1 mips/mipsel build hung indefinitely mid SFTP-transfer under
# qemu-mips-static — auth succeeded, the transfer itself never completed.
# Isolating it to just the OpenSSH side (dropbear's own core build was
# verified fine on mips, byte-identical output) is a plausible next step but
# unverified — reverted outright rather than guess again through another
# slow, hang-risking CI cycle.
CFLAGS="-Os -ffunction-sections -fdata-sections -fomit-frame-pointer $ACFLAGS"
LDFLAGS="-static -Wl,--gc-sections"
[ "${WITH_SFTP:-0}" = '1' ] && CFLAGS="$CFLAGS -DDBMULTI_sftp"

log "building dropbearmulti for $ARCH ($HOST_TRIPLE)"
( cd "$SRC" && ./configure --host="$HOST_TRIPLE" \
	CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
	--enable-static --disable-zlib --disable-pam --disable-shadow \
	--disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
	--disable-loginfunc --disable-pututline --disable-pututxline --disable-openpty \
	>"$WORK/configure.log" 2>&1 ) || { tail -20 "$WORK/configure.log" >&2; die 'configure failed'; }

if ( cd "$SRC" && make -j"$JOBS" \
	PROGRAMS="dbclient dropbear dropbearkey dropbearconvert" MULTI=1 \
	>"$WORK/make.log" 2>&1 ); then
	:
elif [ "${WITH_SFTP:-0}" = '1' ] \
	&& grep -q 'undefined reference to .ossh_sftp_main.\|undefined reference to .ossh_sftp_server_main.' "$WORK/make.log" \
	&& ! grep -viE 'undefined reference to .ossh_sftp|collect2: error: ld returned' "$WORK/make.log" | grep -qiE 'error:'; then
	# Expected at this stage: dbmulti.o references the OpenSSH-side symbols
	# that don't exist until the merge step below links them in. Every object
	# file still got compiled — only dropbear's own (incomplete) final link
	# failed, which the merge step redoes with the missing objects added.
	log "dropbear's own link is missing the SFTP objects as expected — merging them in next"
else
	grep -iE 'error:|undefined' "$WORK/make.log" | head -20 >&2
	die 'build failed'
fi

# Without SFTP, dropbear's own link above is the whole build and must have
# produced the binary already. With SFTP, the merge step below does the real
# final link instead (see the elif above), so the check happens after it.
[ "${WITH_SFTP:-0}" = '1' ] || [ -f "$SRC/dropbearmulti" ] || die 'dropbearmulti was not produced'

# ------------------------------------------------------ merge in SFTP (opt-in)
# Builds OpenSSH's sftp/sftp-server as ordinary objects, resolves the two real
# symbol collisions with Dropbear (`main`, `atomicio` — everything else is
# either musl libc, satisfied once for the whole binary, or C-runtime start
# files that only exist once anyway), and relinks dropbearmulti with them
# spliced in as two more multi-call applets. See patches/sftp-glue.c and
# patches/embedded-sftp-dispatch.patch for the two collisions' resolution.
if [ "${WITH_SFTP:-0}" = '1' ]; then
	log 'building OpenSSH sftp/sftp-server objects for the in-process merge'
	OSSH_VER="${OPENSSH_VER:-9.9p2}"
	OSSH_TARBALL="openssh-$OSSH_VER.tar.gz"
	OSSH_URL="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/$OSSH_TARBALL"
	[ -f "$HERE/src-cache/$OSSH_TARBALL" ] || {
		log "fetching $OSSH_TARBALL"
		curl -fsSL -o "$HERE/src-cache/$OSSH_TARBALL" "$OSSH_URL" || die 'openssh source download failed'
	}

	OWORK="$HERE/.build/openssh-$ARCH"
	rm -rf "$OWORK"
	mkdir -p "$OWORK"
	tar xf "$HERE/src-cache/$OSSH_TARBALL" -C "$OWORK"
	OSRC="$OWORK/openssh-$OSSH_VER"
	[ -d "$OSRC" ] || die 'unexpected openssh source layout'

	# sftp/sftp-server do no asymmetric crypto themselves, so drop OpenSSL/zlib
	# to stay small and fully static; the cache vars answer what configure
	# cannot probe by running target binaries under cross-compilation.
	( cd "$OSRC" && ./configure --host="$HOST_TRIPLE" CC="$CC" \
		--without-openssl --without-zlib --without-pam \
		--without-selinux --without-kerberos5 --disable-utmp --disable-wtmp \
		CFLAGS="-Os -ffunction-sections -fdata-sections" \
		LDFLAGS="-static -Wl,--gc-sections" \
		ac_cv_func_setresuid=yes ac_cv_func_setresgid=yes \
		>"$OWORK/configure.log" 2>&1 ) || { tail -25 "$OWORK/configure.log" >&2; die 'openssh configure failed'; }

	# The final `sftp`/`sftp-server` links this produces are discarded — only
	# the intermediate objects and the two static libs they pulled symbols
	# from (libssh.a, libopenbsd-compat.a) are used below.
	( cd "$OSRC" && make -j"$JOBS" sftp-server sftp >"$OWORK/make.log" 2>&1 ) \
		|| { grep -iE 'error:|undefined' "$OWORK/make.log" | head -20 >&2; die 'openssh build failed'; }

	# Compile the glue file (cleanup_exit + ossh_sftp_server_main, see
	# sftp-glue.c) with whatever flags OpenSSH's own Makefile used for its C
	# files, so it sees the same config.h and include paths.
	OSSH_CC_LINE="$(grep -m1 -- '-c sftp-server-main\.c -o sftp-server-main\.o' "$OWORK/make.log")"
	[ -n "$OSSH_CC_LINE" ] || die 'could not find an OpenSSH compile line to model the glue build on'
	cp "$HERE/patches/sftp-glue.c" "$OSRC/sftp-glue.c"
	( cd "$OSRC" && eval "$(printf '%s' "$OSSH_CC_LINE" | sed 's/sftp-server-main\.c/sftp-glue.c/; s/sftp-server-main\.o/sftp-glue.o/')" ) \
		|| die 'sftp-glue.c compile failed'

	log 'renaming colliding symbols (atomicio, main) in the OpenSSH objects'
	OBJCOPY="${CC%-gcc}-objcopy"
	AR="${CC%-gcc}-ar"
	RENAME_DIR="$OWORK/renamed"
	rm -rf "$RENAME_DIR"
	mkdir -p "$RENAME_DIR/libssh" "$RENAME_DIR/libopenbsd-compat"
	( cd "$RENAME_DIR/libssh" && "$AR" x "$OSRC/libssh.a" )
	( cd "$RENAME_DIR/libopenbsd-compat" && "$AR" x "$OSRC/openbsd-compat/libopenbsd-compat.a" )
	SFTP_OBJS="$OSRC/sftp.o $OSRC/sftp-common.o $OSRC/sftp-client.o $OSRC/sftp-usergroup.o $OSRC/progressmeter.o $OSRC/sftp-glob.o $OSRC/sftp-server.o $OSRC/sftp-glue.o"
	# atomicio: both projects have their own atomicio.c. Applied everywhere
	# (definition + every caller) so the rename stays internally consistent;
	# it's a silent no-op on any object that never mentions the symbol.
	for o in "$RENAME_DIR"/libssh/*.o "$RENAME_DIR"/libopenbsd-compat/*.o $SFTP_OBJS; do
		"$OBJCOPY" --redefine-sym atomicio=ossh_atomicio "$o" 2>/dev/null || true
	done
	# main: only sftp.c's copy needs it — sftp-server's own main()
	# (sftp-server-main.c) is deliberately not linked at all; sftp-glue.c
	# stands in for it.
	"$OBJCOPY" --redefine-sym main=ossh_sftp_main "$OSRC/sftp.o" || die 'renaming sftp.c main failed'
	# sftp_realpath: an OpenSSH-internal collision, not a Dropbear one — the
	# sftp *client* (sftp-client.c) has its own sftp_realpath(conn, path), a
	# completely different function from the sftp *server*'s simple
	# sftp_realpath(path, resolved) in sftp-realpath.c (pulled from the
	# archive). Normally each lives in its own binary; merged, sftp-client.o
	# is a loose object so its definition wins for *every* caller, silently
	# handing sftp-server.o's call a `struct sftp_conn *` where it expects a
	# path string — found by an actual SFTP session crashing (garbage fd,
	# fatal in send_msg) when a client asked for a realpath.
	# objcopy takes at most one positional file (a second one is an *output*
	# path, not a second input) — must be invoked once per file, not given a
	# list.
	"$OBJCOPY" --redefine-sym sftp_realpath=ossh_sftp_client_realpath "$OSRC/sftp-client.o" \
		&& "$OBJCOPY" --redefine-sym sftp_realpath=ossh_sftp_client_realpath "$OSRC/sftp.o" \
		|| die 'renaming sftp-client.c sftp_realpath failed'

	( cd "$RENAME_DIR/libssh" && "$AR" rcs "$RENAME_DIR/libssh-merged.a" *.o )
	( cd "$RENAME_DIR/libopenbsd-compat" && "$AR" rcs "$RENAME_DIR/libopenbsd-compat-merged.a" *.o )

	log 'relinking dropbearmulti with the SFTP objects merged in'
	DB_LINKCMD="$(grep -- '-o dropbearmulti ' "$WORK/make.log" | tail -1)"
	[ -n "$DB_LINKCMD" ] || die 'could not find the dropbearmulti link command in make.log'
	( cd "$SRC" && eval "$DB_LINKCMD $SFTP_OBJS -L$RENAME_DIR -lssh-merged -lopenbsd-compat-merged" ) \
		|| die 'merged dropbearmulti link failed'
fi

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

# SFTP (sftp + sftp-server) is merged into dropbearmulti itself when
# WITH_SFTP=1 (see the merge step above) — nothing extra to copy. The
# embedded server execs SFTPSERVER_PATH ("/tmp/sftp-server") for the
# subsystem: bootstrap.sh --serve symlinks that to dropbearmulti, and
# multi-call dispatch on basename("/tmp/sftp-server") does the rest.
if [ "${WITH_SFTP:-0}" = '1' ]; then
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

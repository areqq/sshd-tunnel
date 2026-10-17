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
# The cross-compiler is `zig cc`: one ~55 MB download covers every target,
# with musl built on demand into a cache instead of seven per-arch toolchains.
# Everything is fetched on demand (zig + Dropbear source), so a clean machine
# needs only curl, tar, make and sha256sum.
#
# Environment:
#   DB_VER      Dropbear version           (default: 2026.94)
#   ZIG_VER     zig release                (default: 0.16.0)
#   OUT_DIR     where the tarball is written (default: client/out)
#   JOBS        parallel make jobs         (default: nproc)
#   WITH_SFTP   1 to merge OpenSSH's sftp + sftp-server into the binary
#   OPENSSH_VER OpenSSH version for WITH_SFTP (default: 9.9p2)

set -eu

ARCH="${1:?usage: build.sh <x86_64|i686|armv7|armv5|aarch64|mips|mipsel>}"
DB_VER="${DB_VER:-2026.94}"
ZIG_VER="${ZIG_VER:-0.16.0}"

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$HERE/out}"
WORK="$HERE/.build/$ARCH"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

DB_TARBALL="dropbear-$DB_VER.tar.bz2"
DB_URL="https://matt.ucc.asn.au/dropbear/releases/$DB_TARBALL"

log() { printf '==> %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

# arch -> zig target + CPU. HOST_TRIPLE is what autoconf's config.sub gets
# (zig's "x86" is not a CPU name it knows, hence the i686 spelling). The CPU
# flag lives inside the compiler wrapper below, so *every* object in the
# binary — Dropbear's, libtom's and OpenSSH's alike — is built for the same
# CPU and float ABI. That was not true with per-project CFLAGS and cost a
# real SIGILL on MIPS once (see TODO.md); it cannot recur this way.
# armv5 and mips/mipsel use the soft-float musl ABI (*eabi, no "hf") because
# that is what the overwhelming majority of those devices ship.
case "$ARCH" in
	x86_64)  ZIG_TARGET='x86_64-linux-musl';     HOST_TRIPLE="$ZIG_TARGET";  ZCPU='' ;;
	i686)    ZIG_TARGET='x86-linux-musl';        HOST_TRIPLE='i686-linux-musl'; ZCPU='-mcpu=i686' ;;
	armv7)   ZIG_TARGET='arm-linux-musleabihf';  HOST_TRIPLE="$ZIG_TARGET";  ZCPU='-mcpu=cortex_a7' ;;
	armv5)   ZIG_TARGET='arm-linux-musleabi';    HOST_TRIPLE="$ZIG_TARGET";  ZCPU='-mcpu=arm926ej_s' ;;
	aarch64) ZIG_TARGET='aarch64-linux-musl';    HOST_TRIPLE="$ZIG_TARGET";  ZCPU='' ;;
	mips)    ZIG_TARGET='mips-linux-musleabi';   HOST_TRIPLE="$ZIG_TARGET";  ZCPU='-mcpu=mips32' ;;
	mipsel)  ZIG_TARGET='mipsel-linux-musleabi'; HOST_TRIPLE="$ZIG_TARGET";  ZCPU='-mcpu=mips32' ;;
	*) die "unknown arch: $ARCH" ;;
esac

for tool in curl tar make sed awk sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done

# ---------------------------------------------------------------- toolchain
# One zig tarball per *host* (the machine running this script), pinned by
# SHA-256 from https://ziglang.org/download/index.json.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
	x86_64)  ZIG_SHA='70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00' ;;
	aarch64) ZIG_SHA='ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17' ;;
	*) die "no pinned zig $ZIG_VER checksum for build host $HOST_ARCH" ;;
esac
[ "$ZIG_VER" = '0.16.0' ] || die "ZIG_VER=$ZIG_VER has no pinned checksum in this script"
ZIG_NAME="zig-$HOST_ARCH-linux-$ZIG_VER"
ZIG_DIR="$HERE/toolchain/$ZIG_NAME"
ZIG="$ZIG_DIR/zig"
if [ ! -x "$ZIG" ]; then
	log "fetching $ZIG_NAME"
	mkdir -p "$HERE/toolchain"
	curl -fsSL -o "$HERE/toolchain/$ZIG_NAME.tar.xz" \
		"https://ziglang.org/download/$ZIG_VER/$ZIG_NAME.tar.xz" || die 'zig download failed'
	printf '%s  %s\n' "$ZIG_SHA" "$HERE/toolchain/$ZIG_NAME.tar.xz" | sha256sum -c --quiet - \
		|| die 'zig tarball checksum mismatch'
	tar xf "$HERE/toolchain/$ZIG_NAME.tar.xz" -C "$HERE/toolchain"
	rm -f "$HERE/toolchain/$ZIG_NAME.tar.xz"
	[ -x "$ZIG" ] || die "zig not found at $ZIG after unpacking"
fi
# musl and compiler-rt are compiled per target on first use; keep that next
# to the toolchain so CI can cache it together with zig itself.
export ZIG_GLOBAL_CACHE_DIR="$HERE/toolchain/zig-cache"
export ZIG_LOCAL_CACHE_DIR="$ZIG_GLOBAL_CACHE_DIR"

# autoconf wants single-word CC/AR/RANLIB named <host>-<tool>; wrap zig's
# sub-commands under those names, with target and CPU baked in.
WRAP="$HERE/.build/wrap-$ARCH"
rm -rf "$WRAP"
mkdir -p "$WRAP"
printf '#!/bin/sh\nexec "%s" cc -target %s %s "$@"\n' "$ZIG" "$ZIG_TARGET" "$ZCPU" > "$WRAP/$HOST_TRIPLE-gcc"
printf '#!/bin/sh\nexec "%s" ar "$@"\n'     "$ZIG" > "$WRAP/$HOST_TRIPLE-ar"
printf '#!/bin/sh\nexec "%s" ranlib "$@"\n' "$ZIG" > "$WRAP/$HOST_TRIPLE-ranlib"
chmod 755 "$WRAP"/*
export PATH="$WRAP:$PATH"
CC="$HOST_TRIPLE-gcc"; AR="$HOST_TRIPLE-ar"; RANLIB="$HOST_TRIPLE-ranlib"
export CC AR RANLIB

# ---------------------------------------------------- pre-ARMv6 atomics (armv5)
# ARMv5 has no LDREX/STREX, so clang emits calls to the legacy __sync_*
# libcalls; zig's compiler-rt does not implement them while zig's own C runtime
# (libzigc's SmpAllocator, which backs malloc) calls three of them, so the link
# fails without these. See patches/arm-pre-v6-sync.c.
# Passed as a plain object rather than an archive: LDFLAGS lands *before* the
# object files on dropbear's link line, and an archive there would only be
# scanned for what was already undefined at that point — an ordering an
# archive would depend on and an object does not.
EXTRA_LIBS=''
if [ "$ARCH" = 'armv5' ]; then
	log 'building the pre-ARMv6 __sync_* helpers'
	# Not under $WORK: that is wiped when the source is unpacked below.
	SYNC_DIR="$HERE/.build/armsync-$ARCH"
	rm -rf "$SYNC_DIR"
	mkdir -p "$SYNC_DIR"
	# -fno-builtin: clang otherwise refuses to let a translation unit define a
	# function it knows as a builtin ("cannot redeclare builtin function").
	"$CC" -c -Os -fno-builtin -o "$SYNC_DIR/arm-pre-v6-sync.o" \
		"$HERE/patches/arm-pre-v6-sync.c" \
		|| die 'pre-ARMv6 atomics failed to compile'
	EXTRA_LIBS="$SYNC_DIR/arm-pre-v6-sync.o"

	# A wrong return value from one of these would link fine and log in fine,
	# then corrupt the allocator's state under contention, so assert the
	# semantics directly rather than inferring them from a working binary.
	if command -v qemu-arm-static >/dev/null 2>&1; then
		"$CC" -Os -static -o "$SYNC_DIR/sync-test" \
			"$HERE/patches/arm-pre-v6-sync-test.c" "$HERE/patches/arm-pre-v6-sync.c" \
			|| die 'pre-ARMv6 atomics test failed to build'
		qemu-arm-static "$SYNC_DIR/sync-test" || die 'pre-ARMv6 atomics test failed'
	else
		log 'qemu-arm-static not installed: skipping the pre-ARMv6 atomics test'
	fi
fi

# ------------------------------------------------------- MIPS o32 pipe() fix
# zig 0.16.0's C runtime ships a pipe() that ignores the MIPS o32 convention
# (both descriptors come back in registers, not through the pointer), which
# breaks the server's child-process plumbing while leaving auth and the socket
# path working — a login that succeeds and produces no output. Linked as a
# loose object so it resolves pipe() ahead of any archive.
# See patches/mips-o32-pipe.c.
if [ "$ARCH" = 'mips' ] || [ "$ARCH" = 'mipsel' ]; then
	log 'building the MIPS o32 pipe() override'
	PIPE_DIR="$HERE/.build/mipspipe-$ARCH"
	rm -rf "$PIPE_DIR"
	mkdir -p "$PIPE_DIR"
	"$CC" -c -Os -o "$PIPE_DIR/mips-o32-pipe.o" "$HERE/patches/mips-o32-pipe.c" \
		|| die 'MIPS o32 pipe() override failed to compile'
	EXTRA_LIBS="$PIPE_DIR/mips-o32-pipe.o"

	# The failure this fixes is invisible to a link and to authentication, so
	# assert the syscall behaviour itself, including a child's output arriving
	# through a pipe.
	QEMU_FOR_TEST="qemu-$ARCH-static"
	if command -v "$QEMU_FOR_TEST" >/dev/null 2>&1; then
		"$CC" -Os -static -o "$PIPE_DIR/pipe-test" \
			"$HERE/patches/mips-o32-pipe-test.c" "$HERE/patches/mips-o32-pipe.c" \
			|| die 'MIPS o32 pipe() test failed to build'
		"$QEMU_FOR_TEST" "$PIPE_DIR/pipe-test" || die 'MIPS o32 pipe() test failed'
	else
		log "$QEMU_FOR_TEST not installed: skipping the MIPS o32 pipe() test"
	fi
fi

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
# Stripping happens at link time (-Wl,-s): `zig objcopy --strip-all` is
# unimplemented as of 0.16.0 and there is no `zig strip`.
# -flto was tried (with gcc) and reverted: the bundled libtomcrypt.a /
# libtommath.a are plain archives placed once at the end of the link line and
# LTO discovered its need for their symbols too late — see TODO.md.
CFLAGS="-Os -ffunction-sections -fdata-sections -fomit-frame-pointer"
LDFLAGS="-static -Wl,--gc-sections -Wl,-s $EXTRA_LIBS"
[ "${WITH_SFTP:-0}" = '1' ] && CFLAGS="$CFLAGS -DDBMULTI_sftp"

log "building dropbearmulti for $ARCH ($ZIG_TARGET $ZCPU, zig $ZIG_VER)"
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
	&& undef_syms="$(grep -oE "undefined (symbol: |reference to .)[A-Za-z0-9_]+" "$WORK/make.log" \
		| sed -E 's/.*(symbol: |reference to .)//' | sort -u)" \
	&& [ -n "$undef_syms" ] \
	&& ! printf '%s\n' "$undef_syms" \
		| grep -vE '^ossh_sftp_(server_)?main$' | grep -q .; then
	# Expected at this stage: dbmulti.o references the OpenSSH-side symbols
	# that don't exist until the merge step below links them in. Every object
	# file still got compiled — only dropbear's own (incomplete) final link
	# failed, which the merge step redoes with the missing objects added.
	# The condition above asserts the actual invariant: the *only* symbols the
	# link could not resolve are those two. (Matching on the word "error"
	# instead is not safe here — libtommath has a file called
	# bn_mp_error_to_string.c, so its compile lines and warnings carry the
	# word without anything being wrong.)
	log "dropbear's own link is missing the SFTP objects as expected — merging them in next"
else
	grep -iE 'error|undefined' "$WORK/make.log" | head -20 >&2
	die 'build failed'
fi

# Without SFTP, dropbear's own link above is the whole build and must have
# produced the binary already. With SFTP, the merge step below does the real
# final link instead (see the elif above), so the check happens after it.
[ "${WITH_SFTP:-0}" = '1' ] || [ -f "$SRC/dropbearmulti" ] || die 'dropbearmulti was not produced'

# ------------------------------------------------------ merge in SFTP (opt-in)
# Builds OpenSSH's sftp/sftp-server as ordinary objects, resolves the three
# real symbol collisions by renaming at compile time (-D<old>=<new> on the
# preprocessor, so definition, declaration and every caller move together),
# and relinks dropbearmulti with them spliced in as two more multi-call
# applets. See patches/sftp-glue.c and patches/embedded-sftp-dispatch.patch.
# The collisions:
#   atomicio      both projects have their own atomicio.c — renamed in every
#                 OpenSSH object (via CFLAGS), a no-op where it isn't used
#   main          sftp.c's — only that one file; sftp-server's own main()
#                 (sftp-server-main.c) is not linked at all, sftp-glue.c
#                 stands in for it
#   sftp_realpath an OpenSSH-*internal* clash: the sftp client's
#                 sftp_realpath(conn, path) and the server's unrelated
#                 sftp_realpath(path, resolved) share a name. Normally each
#                 lives in its own binary; merged, one definition would win
#                 for every caller and the server handler would get a
#                 `struct sftp_conn *` where it expects a path — found as a
#                 real crash (garbage fd, fatal in send_msg). The client-side
#                 pair (sftp-client.c, sftp.c) is renamed.
# Compile-time renaming replaced `objcopy --redefine-sym` when the build
# moved to zig, which ships no objcopy that can rename symbols.
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
	# Target CPU / float ABI come from the $CC wrapper, identical to
	# dropbear's own objects by construction.
	# $EXTRA_LIBS has to be here as well as in dropbear's own LDFLAGS: on
	# armv5 every configure link test fails without the __sync_* helpers, and
	# a configure that cannot link concludes the function it was probing for
	# is missing. That produced a build error in OpenSSH's getdelim
	# replacement, which musl does have and does declare.
	( cd "$OSRC" && ./configure --host="$HOST_TRIPLE" CC="$CC" \
		--without-openssl --without-zlib --without-pam \
		--without-selinux --without-kerberos5 --disable-utmp --disable-wtmp \
		CFLAGS="-Os -ffunction-sections -fdata-sections -Datomicio=ossh_atomicio" \
		LDFLAGS="-static -Wl,--gc-sections $EXTRA_LIBS" \
		ac_cv_func_setresuid=yes ac_cv_func_setresgid=yes \
		>"$OWORK/configure.log" 2>&1 ) || { tail -25 "$OWORK/configure.log" >&2; die 'openssh configure failed'; }

	# The final `sftp`/`sftp-server` links this produces are discarded — only
	# the intermediate objects and the two static libs they pulled symbols
	# from (libssh.a, libopenbsd-compat.a) are used below.
	( cd "$OSRC" && make -j"$JOBS" sftp-server sftp >"$OWORK/make.log" 2>&1 ) \
		|| { grep -iE 'error:|undefined' "$OWORK/make.log" | head -20 >&2; die 'openssh build failed'; }

	# Recompile a file with the exact flags OpenSSH's own Makefile used for it
	# (same config.h, same include paths), plus extra defines.
	#   ossh_recompile <src.c> <obj.o> <extra flags...>
	ossh_recompile() {
		src="$1"; obj="$2"; shift 2
		line="$(grep -m1 -- "-c $src -o $obj" "$OWORK/make.log")" \
			|| die "could not find OpenSSH's compile line for $src"
		( cd "$OSRC" && eval "$line $*" ) || die "recompiling $src failed"
	}
	log 'renaming colliding symbols (main, sftp_realpath) in the sftp client objects'
	ossh_recompile sftp.c sftp.o -Dmain=ossh_sftp_main -Dsftp_realpath=ossh_sftp_client_realpath
	ossh_recompile sftp-client.c sftp-client.o -Dsftp_realpath=ossh_sftp_client_realpath

	# Compile the glue file (cleanup_exit + ossh_sftp_server_main, see
	# sftp-glue.c) with the flags OpenSSH used for sftp-server-main.c.
	cp "$HERE/patches/sftp-glue.c" "$OSRC/sftp-glue.c"
	OSSH_CC_LINE="$(grep -m1 -- '-c sftp-server-main\.c -o sftp-server-main\.o' "$OWORK/make.log")" \
		|| die 'could not find an OpenSSH compile line to model the glue build on'
	( cd "$OSRC" && eval "$(printf '%s' "$OSSH_CC_LINE" | sed 's/sftp-server-main\.c/sftp-glue.c/; s/sftp-server-main\.o/sftp-glue.o/')" ) \
		|| die 'sftp-glue.c compile failed'

	SFTP_OBJS="$OSRC/sftp.o $OSRC/sftp-common.o $OSRC/sftp-client.o $OSRC/sftp-usergroup.o $OSRC/progressmeter.o $OSRC/sftp-glob.o $OSRC/sftp-server.o $OSRC/sftp-glue.o"

	log 'relinking dropbearmulti with the SFTP objects merged in'
	DB_LINKCMD="$(grep -- '-o dropbearmulti ' "$WORK/make.log" | tail -1)"
	[ -n "$DB_LINKCMD" ] || die 'could not find the dropbearmulti link command in make.log'
	( cd "$SRC" && eval "$DB_LINKCMD $SFTP_OBJS -L$OSRC -L$OSRC/openbsd-compat -lssh -lopenbsd-compat" ) \
		>"$WORK/relink.log" 2>&1 || { tail -30 "$WORK/relink.log" >&2; die 'merged dropbearmulti link failed'; }
fi

[ -f "$SRC/dropbearmulti" ] || die 'dropbearmulti was not produced'

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
printf '    %s\n' "$(cd "$SRC" && ls -l dropbearmulti | awk '{print $5" bytes"}')"

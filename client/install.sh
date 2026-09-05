#!/bin/sh
# Detect this device's architecture, download the matching dropbear-tunnel
# release, unpack it under /tmp, and prove the binary actually runs here.
#
#   wget -qO- https://raw.githubusercontent.com/areqq/sshd-tunnel/main/client/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/areqq/sshd-tunnel/main/client/install.sh | sh
#
# Nothing is written outside the install directory (/tmp by default), nothing
# is started, and no configuration on the device is touched — this only puts
# a verified binary in place. Run bootstrap.sh afterwards to open a tunnel.
#
# Target: busybox ash on a device from around 2014, and deliberately poorer.
# Every non-POSIX convenience is either avoided or has a fallback: no mktemp,
# no `command` builtin, no id/od/find -maxdepth/diff/cmp, no bashisms. These
# are not hypothetical — each one is missing on at least one of the routers
# this was tested against.
#
# Environment:
#   DBT_REPO     owner/name              (default: areqq/sshd-tunnel)
#   DBT_VERSION  release tag or latest   (default: latest client-v* release)
#   DBT_ARCH     override the detection  (default: autodetected)
#   DBT_DIR      install directory       (default: /tmp/dropbear-tunnel)
#   DBT_SFTP     1 to fetch the SFTP-enabled build instead of the core one

set -eu

PROG='dropbear-tunnel-install'
REPO="${DBT_REPO:-areqq/sshd-tunnel}"
VERSION="${DBT_VERSION:-latest}"
DEST="${DBT_DIR:-/tmp/dropbear-tunnel}"
WORK="/tmp/.dbt-install.$$"

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

# `command -v` is a POSIX builtin, but at least one router in the wild
# (ASUSWRT-Merlin's busybox ash) does not have it and reports
# "command: not found" — so always keep `which` as the fallback.
have() {
	command -v "$1" >/dev/null 2>&1 && return 0
	which "$1" >/dev/null 2>&1
}

for t in tar uname; do
	have "$t" || die "need $t"
done

# ----------------------------------------------------------------- download
if have curl; then
	fetch() { curl -fsSL -o "$2" "$1"; }
	fetch_out() { curl -fsSL "$1"; }
elif have wget; then
	# Old busybox wget has neither -q nor --no-check-certificate in every
	# build, and some have no CA bundle at all, so degrade step by step.
	fetch() {
		wget -q -O "$2" "$1" 2>/dev/null && return 0
		wget -O "$2" "$1" 2>/dev/null && return 0
		wget --no-check-certificate -O "$2" "$1" 2>/dev/null
	}
	fetch_out() {
		wget -q -O- "$1" 2>/dev/null && return 0
		wget -O- "$1" 2>/dev/null && return 0
		wget --no-check-certificate -O- "$1" 2>/dev/null
	}
else
	die 'need curl or wget'
fi

# ------------------------------------------------------------ architecture
# uname -m cannot tell big- from little-endian MIPS: every MIPS router tested
# reports plain "mips" either way. So for MIPS the endianness is read out of
# an ELF header on the device itself — byte 5 (EI_DATA) is 1 for
# little-endian, 2 for big-endian.
elf_endian() {
	_elf=''
	for _c in /bin/sh /bin/busybox /bin/true /bin/cat; do
		if [ -r "$_c" ]; then _elf="$_c"; break; fi
	done
	[ -n "$_elf" ] || return 1

	_b="$(dd if="$_elf" bs=1 skip=5 count=1 2>/dev/null | od -An -tu1 2>/dev/null | tr -dc '0-9')"
	if [ -z "$_b" ]; then
		_b="$(dd if="$_elf" bs=1 skip=5 count=1 2>/dev/null | hexdump -v -e '1/1 "%u"' 2>/dev/null | tr -dc '0-9')"
	fi
	if [ -n "$_b" ]; then
		case "$_b" in
			1) echo le; return 0 ;;
			2) echo be; return 0 ;;
		esac
	fi

	# Neither od nor hexdump (both genuinely absent on some boxes): compare
	# the raw byte against references written with printf.
	mkdir -p "$WORK" 2>/dev/null || true
	printf '\001' > "$WORK/.le" 2>/dev/null || return 1
	printf '\002' > "$WORK/.be" 2>/dev/null || return 1
	dd if="$_elf" bs=1 skip=5 count=1 2>/dev/null > "$WORK/.byte" || return 1
	if cmp -s "$WORK/.byte" "$WORK/.le" 2>/dev/null; then echo le; return 0; fi
	if cmp -s "$WORK/.byte" "$WORK/.be" 2>/dev/null; then echo be; return 0; fi
	return 1
}

detect_arch() {
	_m="$(uname -m 2>/dev/null || echo unknown)"
	case "$_m" in
		x86_64|amd64)        echo x86_64 ;;
		i[3456]86)           echo i686 ;;
		aarch64|arm64)       echo aarch64 ;;
		armv7*|armv8l)       echo armv7 ;;
		# armv6 and bare "arm" get the soft-float armv5 build: it runs
		# everywhere in that family, where the hard-float armv7 build
		# would not.
		armv6*|armv5*|armv4*|arm) echo armv5 ;;
		mips64*)             die "no build for $_m (64-bit MIPS is not in the matrix)" ;;
		mipsel|mipsle)       echo mipsel ;;
		mips)
			_e="$(elf_endian || true)"
			case "$_e" in
				le) echo mipsel ;;
				be) echo mips ;;
				*)  die 'cannot tell big- from little-endian MIPS; set DBT_ARCH=mips or DBT_ARCH=mipsel' ;;
			esac
			;;
		*) die "unsupported architecture: $_m (set DBT_ARCH to override)" ;;
	esac
}

if [ -n "${DBT_ARCH:-}" ]; then
	ARCH="$DBT_ARCH"
else
	ARCH="$(detect_arch)"
fi
say "architecture: $ARCH"

if [ "${DBT_SFTP:-0}" = '1' ]; then
	TARBALL="dropbear-tunnel-$ARCH-sftp.tgz"
else
	TARBALL="dropbear-tunnel-$ARCH.tgz"
fi

# --------------------------------------------------------------- release tag
# The repo carries both server (v*) and client (client-v*) releases, so
# "latest" has to mean the latest *client* one, not whatever was tagged last.
if [ "$VERSION" = 'latest' ]; then
	say 'looking up the latest client release'
	VERSION="$(fetch_out "https://api.github.com/repos/$REPO/releases" 2>/dev/null \
		| tr ',' '\n' \
		| grep '"tag_name"' \
		| grep 'client-v' \
		| head -1 \
		| sed -e 's/.*"\(client-v[^"]*\)".*/\1/')" || true
	[ -n "$VERSION" ] || die 'cannot determine the latest client-v* release; set DBT_VERSION'
fi
say "release: $VERSION"

BASE_URL="https://github.com/$REPO/releases/download/$VERSION"

# ------------------------------------------------------------------ download
mkdir -p "$WORK" || die "cannot create $WORK"

say "downloading $TARBALL"
fetch "$BASE_URL/$TARBALL" "$WORK/$TARBALL" || die "cannot download $BASE_URL/$TARBALL"
[ -s "$WORK/$TARBALL" ] || die "downloaded $TARBALL is empty"

# The checksum is verified when the device has something to verify it with;
# a box with neither sha256sum nor openssl still gets a working install, just
# with a warning rather than a hard failure it cannot do anything about.
if fetch "$BASE_URL/$TARBALL.sha256" "$WORK/$TARBALL.sha256" 2>/dev/null && [ -s "$WORK/$TARBALL.sha256" ]; then
	WANT="$(cut -d' ' -f1 < "$WORK/$TARBALL.sha256")"
	GOT=''
	if have sha256sum; then
		GOT="$(sha256sum "$WORK/$TARBALL" | cut -d' ' -f1)"
	elif have shasum; then
		GOT="$(shasum -a 256 "$WORK/$TARBALL" | cut -d' ' -f1)"
	elif have openssl; then
		GOT="$(openssl dgst -sha256 "$WORK/$TARBALL" 2>/dev/null | sed -e 's/.*[= ]//')"
	fi
	if [ -z "$GOT" ]; then
		say 'WARNING: no sha256 tool on this device, skipping checksum verification'
	elif [ "$WANT" = "$GOT" ]; then
		say 'checksum verified'
	else
		die "checksum mismatch: expected $WANT, got $GOT"
	fi
else
	say 'WARNING: no published checksum found, skipping verification'
fi

# -------------------------------------------------------------------- unpack
mkdir -p "$WORK/unpacked" || die 'cannot create the unpack directory'
tar xzf "$WORK/$TARBALL" -C "$WORK/unpacked" || die 'cannot unpack the tarball'

# busybox find has no -maxdepth on some builds, so glob instead.
SRC=''
for d in "$WORK"/unpacked/dropbear-tunnel-*; do
	if [ -d "$d" ]; then SRC="$d"; break; fi
done
[ -n "$SRC" ] || die 'unexpected tarball layout'

if [ -e "$DEST" ]; then
	say "replacing the existing installation in $DEST"
	rm -rf "$DEST"
fi
mkdir -p "$(dirname -- "$DEST")" 2>/dev/null || true
mv "$SRC" "$DEST" || die "cannot install into $DEST"

BIN="$DEST/dropbearmulti"
[ -f "$BIN" ] || die "dropbearmulti missing from the tarball"
chmod 755 "$BIN" 2>/dev/null || true
for f in patch-cred bootstrap.sh dbclient; do
	if [ -e "$DEST/$f" ]; then chmod 755 "$DEST/$f" 2>/dev/null || true; fi
done
say "installed into $DEST"

# --------------------------------------------------------------- smoke test
# Not just "does it exec" — generating a key runs the real crypto code on
# this CPU. That is what catches a binary built for the wrong ABI, which is
# exactly how a hard-float/soft-float mismatch showed up on real MIPS
# hardware as an illegal instruction while every emulator was happy with it.
say 'checking that the binary runs on this CPU'
if ! "$BIN" dropbearkey -t ed25519 -f "$WORK/smoke_key" >/dev/null 2>&1; then
	die "the binary does not run here — wrong architecture? (detected $ARCH; override with DBT_ARCH)"
fi
rm -f "$WORK/smoke_key" "$WORK/smoke_key.pub"
say 'OK: key generation succeeded, the binary works on this device'

VER="$("$BIN" dbclient -h 2>&1 | head -1 || true)"
if [ -n "$VER" ]; then say "$VER"; fi

cat <<EOF

Installed and verified: $DEST

  $DEST/dropbearmulti    dbclient / dropbear / dropbearkey / dropbearconvert
  $DEST/patch-cred       swap an embedded credential without recompiling
  $DEST/bootstrap.sh     open the reverse tunnel

Open a tunnel back to your server (device port 2222 shows up there as 22022):

  $DEST/bootstrap.sh you@your-server -R 22022:127.0.0.1:2222

Add --serve to also start the embedded SSH server, so you can log back in
through that tunnel using the key baked into the binary.
EOF

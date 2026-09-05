# Body of the DSVPN bootstrap script served over HTTP. /dsvpn.sh prepends a
# header of shell-quoted variable assignments and serves the concatenation;
# this file contains no placeholders, so no value ever needs sed-escaping.
#
# Expected variables: SRV VPN_PORT HTTP_PORT TOKEN VPN_LOCAL VPN_REMOTE
# Overridable from the environment: DIR DSV_ARCH
#
# The difference from vpn-body.sh: that one needs openvpn already installed on
# the device, which is exactly what many of these boxes do not have. Here the
# ~100 kB static binary comes down with the key, from this server, over plain
# HTTP — no package manager, no TLS, no internet access on the device.
#
# Target: busybox ash on a device from around 2014. Nothing here may rely on
# bash, on GNU coreutils flags, or on TLS.

set -u

PROG='sshd-tunnel-dsvpn'
say() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# `command -v` is a POSIX builtin, but ASUSWRT-Merlin's busybox ash does not
# have it and reports "command: not found" — keep `which` as the fallback.
have() {
	command -v "$1" >/dev/null 2>&1 && return 0
	which "$1" >/dev/null 2>&1
}

DIR="${DIR:-/tmp/sshd-tunnel-dsvpn}"
mkdir -p "$DIR" || { say "cannot create $DIR"; exit 1; }
chmod 700 "$DIR" 2>/dev/null

BIN="$DIR/dsvpn"
KEY="$DIR/dsvpn.key"

# ------------------------------------------------------------------ preflight
# All three of these fail later and more confusingly than they do here.
if [ "$(id -u 2>/dev/null || echo 0)" != '0' ]; then
	say 'this needs root: creating a tun device and assigning addresses is privileged'
	exit 1
fi
if [ ! -c /dev/net/tun ]; then
	say 'no /dev/net/tun on this device'
	say 'try: mkdir -p /dev/net && mknod /dev/net/tun c 10 200 && modprobe tun'
	exit 1
fi
if ! have ip; then
	say 'no `ip` command here — dsvpn configures the interface by running it'
	exit 1
fi

fetch() {
	if have wget; then
		wget -q -O "$2" "$1" 2>/dev/null && return 0
		wget -O "$2" "$1" 2>/dev/null && return 0
	fi
	if have curl; then
		curl -fsS -o "$2" "$1" && return 0
	fi
	return 1
}

# ------------------------------------------------------------- architecture
# uname -m cannot tell big- from little-endian MIPS: every MIPS router tested
# reports plain "mips" either way. So for MIPS the endianness is read out of an
# ELF header on the device itself — byte 5 (EI_DATA) is 1 for little-endian,
# 2 for big-endian. Same logic as client/install.sh; kept duplicated rather
# than shared because this file is served standalone over HTTP.
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

	# Neither od nor hexdump (both genuinely absent on some boxes): compare the
	# raw byte against references written with printf.
	printf '\001' > "$DIR/.le" 2>/dev/null || return 1
	printf '\002' > "$DIR/.be" 2>/dev/null || return 1
	dd if="$_elf" bs=1 skip=5 count=1 2>/dev/null > "$DIR/.byte" || return 1
	if cmp -s "$DIR/.byte" "$DIR/.le" 2>/dev/null; then echo le; return 0; fi
	if cmp -s "$DIR/.byte" "$DIR/.be" 2>/dev/null; then echo be; return 0; fi
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
		# everywhere in that family, where the hard-float armv7 build would not.
		armv6*|armv5*|armv4*|arm) echo armv5 ;;
		mips64*)             say "no build for $_m (64-bit MIPS is not in the matrix)"; return 1 ;;
		mipsel|mipsle)       echo mipsel ;;
		mips)
			_e="$(elf_endian || true)"
			case "$_e" in
				le) echo mipsel ;;
				be) echo mips ;;
				*)  say 'cannot tell big- from little-endian MIPS; re-run with DSV_ARCH=mips or DSV_ARCH=mipsel'
				    return 1 ;;
			esac
			;;
		*) say "unsupported architecture: $_m (set DSV_ARCH to override)"; return 1 ;;
	esac
}

if [ -n "${DSV_ARCH:-}" ]; then
	ARCH="$DSV_ARCH"
else
	ARCH="$(detect_arch)" || exit 1
fi
say "architecture: $ARCH"

# --------------------------------------------------------- binary and key
if ! fetch "http://$SRV:$HTTP_PORT/t/$TOKEN/bin/dsvpn-$ARCH" "$BIN"; then
	say "cannot fetch the $ARCH binary from http://$SRV:$HTTP_PORT/t/$TOKEN/bin/"
	say 'the server may have been built without the dsvpn binaries embedded'
	exit 1
fi
[ -s "$BIN" ] || { say 'the fetched binary is empty'; exit 1; }
chmod 755 "$BIN" 2>/dev/null

if ! fetch "http://$SRV:$HTTP_PORT/t/$TOKEN/dsvpn.key" "$KEY"; then
	say "cannot fetch http://$SRV:$HTTP_PORT/t/$TOKEN/dsvpn.key"
	exit 1
fi
[ -s "$KEY" ] || { say 'the fetched key is empty'; exit 1; }
chmod 600 "$KEY" 2>/dev/null

# Prove it runs on this CPU before it is asked to do anything. A binary for
# the wrong architecture fails to exec, and one with the wrong float ABI dies
# with SIGILL — both of which would otherwise surface as an unexplained silent
# failure. With no arguments dsvpn prints its usage and exits 254.
if ! "$BIN" 2>&1 | grep -q DSVPN; then
	say "the binary does not run here — wrong architecture? (detected $ARCH; override with DSV_ARCH)"
	exit 1
fi
say 'binary verified'

# --------------------------------------------------------------- connect
say "connecting to $SRV:$VPN_PORT (tcp) — this device becomes $VPN_LOCAL, the server is $VPN_REMOTE"

# dsvpn reconnects by itself with a backoff, so there is no retry loop around
# it, the same as the openvpn mode. It configures nothing on this device
# beyond bringing its own tun interface up and giving it these two addresses:
# the routing table, the firewall and every sysctl are left exactly as they
# are (see vpn-client/patches/no-system-changes.patch).
exec "$BIN" client "$KEY" "$SRV" "$VPN_PORT" auto "$VPN_LOCAL" "$VPN_REMOTE"

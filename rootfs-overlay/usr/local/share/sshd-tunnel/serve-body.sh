# Body of the --serve bootstrap script served over HTTP. /run.sh prepends a
# header of shell-quoted variable assignments and serves the concatenation;
# this file contains no placeholders, so no value ever needs sed-escaping.
#
# Expected variables: SRV SSH_PORT HTTP_PORT TOKEN RPORT LHOST LPORT
# Overridable from the environment: DIR DBT_ARCH LOOP
#
# What it does on the device: fetches a static dropbearmulti built for this
# CPU, with three credentials already patched into it by the server (the
# identity it dials out with, the host key its own SSH server presents, and
# the one public key that server accepts), starts that SSH server on the
# loopback port, and opens the reverse tunnel that exposes it on the server.
# From then on `ssh -p $RPORT <user>@<server>` lands on this device.
#
# Target: busybox ash on a device from around 2014. Nothing here may rely on
# bash, on GNU coreutils flags, or on TLS.

set -u

PROG='sshd-tunnel-serve'
say() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# `command -v` is a POSIX builtin, but ASUSWRT-Merlin's busybox ash does not
# have it and reports "command: not found" — keep `which` as the fallback.
have() {
	command -v "$1" >/dev/null 2>&1 && return 0
	which "$1" >/dev/null 2>&1
}

DIR="${DIR:-/tmp/sshd-tunnel-serve}"
mkdir -p "$DIR" || { say "cannot create $DIR"; exit 1; }
chmod 700 "$DIR" 2>/dev/null

BIN="$DIR/dropbearmulti"
SRV_LOG="$DIR/server.log"

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
# 2 for big-endian. Same logic as client/install.sh and dsvpn-body.sh; kept
# duplicated rather than shared because this file is served standalone.
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
				*)  say 'cannot tell big- from little-endian MIPS; re-run with DBT_ARCH=mips or DBT_ARCH=mipsel'
				    return 1 ;;
			esac
			;;
		*) say "unsupported architecture: $_m (set DBT_ARCH to override)"; return 1 ;;
	esac
}

if [ -n "${DBT_ARCH:-}" ]; then
	ARCH="$DBT_ARCH"
else
	ARCH="$(detect_arch)" || exit 1
fi
say "architecture: $ARCH"

# ---------------------------------------------------------------- the binary
if ! fetch "http://$SRV:$HTTP_PORT/t/$TOKEN/bin/dropbearmulti-$ARCH" "$BIN"; then
	say "cannot fetch the $ARCH binary from http://$SRV:$HTTP_PORT/t/$TOKEN/bin/"
	say 'the server may have been built without the dropbear binaries embedded'
	exit 1
fi
[ -s "$BIN" ] || { say 'the fetched binary is empty'; exit 1; }
chmod 755 "$BIN" 2>/dev/null

# Prove it runs on this CPU before it is asked to do anything. A binary for
# the wrong architecture fails to exec, and one with the wrong float ABI dies
# with SIGILL — both of which would otherwise surface as an unexplained silent
# failure. With no arguments dropbearmulti prints its applet list.
if ! "$BIN" 2>&1 | grep -q Dropbear; then
	say "the binary does not run here — wrong architecture? (detected $ARCH; override with DBT_ARCH)"
	exit 1
fi
say 'binary verified'

# ------------------------------------------------------------ the SSH server
# The host key must be the embedded one, so that the fingerprint the server
# printed is the one the operator sees even on a device with its own
# /etc/dropbear. Dropbear loads its default key files only when no -r is
# given, and -r naming a file that does not exist is a logged warning, after
# which the embedded key is used. (-r /dev/null is not an option: an empty
# file parses as a truncated key and is fatal, "Bad buf_getptr".) Password
# authentication is compiled out of this build; the embedded authorized key
# is the only way in.
cleanup() {
	[ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null
	return 0
}
# The signal traps must exit, not just clean up: a trap that returns lets
# the retry loop below continue after Ctrl-C, with the device's SSH server
# already killed, and nothing short of kill -9 then stops it.
trap cleanup EXIT
trap 'say "interrupted"; exit 130' INT TERM HUP

# SFTP builds exec /tmp/sftp-server for the subsystem; multi-call dispatch
# keys off argv[0], so a symlink is all that takes. Core builds have no such
# applet and skip this.
if [ ! -e /tmp/sftp-server ] && "$BIN" 2>&1 | grep -q "'sftp-server'"; then
	ln -sf "$BIN" /tmp/sftp-server 2>/dev/null && say 'staged sftp-server -> dropbearmulti'
fi

say "starting the SSH server on $LHOST:$LPORT"
"$BIN" dropbear -F -E -r "$DIR/no-hostkey-on-disk" -p "$LHOST:$LPORT" >"$SRV_LOG" 2>&1 &
SRV_PID=$!
sleep 1
if ! kill -0 "$SRV_PID" 2>/dev/null; then
	say 'the SSH server exited immediately:'
	sed 's/^/    /' "$SRV_LOG" >&2
	exit 1
fi

# ------------------------------------------------------------------ connect
say "exposing this device's $LHOST:$LPORT as $SRV:$RPORT"

connect() {
	# The identity comes from the embedded slot, so there is no -i. -y -y
	# accepts the server's host key without a known_hosts file; -K 30
	# keepalive, -I 0 no idle timeout, -N no remote command.
	"$BIN" dbclient -y -y -K 30 -I 0 -N \
		-R "$RPORT:$LHOST:$LPORT" -p "$SSH_PORT" "tcp@$SRV" </dev/null
}

DELAY=5
while :; do
	connect || true

	[ "${LOOP:-1}" = '1' ] || break

	say "disconnected, retrying in ${DELAY}s"
	sleep "$DELAY"
	# Back off to a minute so a permanently rejected client does not hammer
	# the server, but stay responsive for ordinary link flaps.
	DELAY=$((DELAY * 2))
	[ "$DELAY" -le 60 ] || DELAY=60
done

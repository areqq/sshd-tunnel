#!/bin/sh
# Run on the device: open a reverse tunnel to your server and keep it up.
#
#   ./bootstrap.sh <user@server> [options]
#
# The client identity is embedded in dropbearmulti (the patched 'id' slot), so
# no key file is needed on the device. With --serve, the embedded Dropbear
# server is started on a loopback port first and exposed through the tunnel, so
# you can SSH back into the device using the embedded authorized key.
#
# Options:
#   -p <port>     SSH port on your server                 (default: 22)
#   -R <r:h:p>    what to expose on your server:
#                 server_port : device_host : device_port (default: 22022:127.0.0.1:2222)
#   --serve       start the embedded Dropbear server first, on the device_host:device_port
#                 named by -R (uses the embedded host key and authorized key)
#   --bin <path>  path to dropbearmulti                   (default: alongside this script)
#   --once        connect once, do not loop
#
# Target: busybox ash on an embedded device. POSIX only, no bashisms.

set -u

PROG='dropbear-tunnel'
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd 2>/dev/null || echo .)"

SERVER=''
PORT=22
FWD='22022:127.0.0.1:2222'
SERVE=0
ONCE=0
BIN="$HERE/dropbearmulti"

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { say "$*"; exit 1; }

[ $# -gt 0 ] || die 'usage: bootstrap.sh <user@server> [options]  (see header)'
SERVER="$1"; shift
case "$SERVER" in -*|'') die 'first argument must be user@server' ;; esac

while [ $# -gt 0 ]; do
	case "$1" in
		-p)      [ $# -ge 2 ] || die '-p needs a port';   PORT="$2"; shift ;;
		-R)      [ $# -ge 2 ] || die '-R needs r:h:p';     FWD="$2";  shift ;;
		--serve) SERVE=1 ;;
		--once)  ONCE=1 ;;
		--bin)   [ $# -ge 2 ] || die '--bin needs a path'; BIN="$2"; shift ;;
		*)       die "unknown option: $1" ;;
	esac
	shift
done

[ -x "$BIN" ] || die "dropbearmulti not found or not executable: $BIN"

# Split -R r:h:p into its pieces for the embedded server bind.
RPORT="${FWD%%:*}"
REST="${FWD#*:}"
LHOST="${REST%:*}"
LPORT="${REST##*:}"
case "$FWD" in *:*:*) ;; *) die "-R must look like rport:host:port, got: $FWD" ;; esac

# ------------------------------------------------------------- embedded server
SRV_PID=''
if [ "$SERVE" -eq 1 ]; then
	# SFTP is merged into dropbearmulti itself as another multi-call applet
	# (WITH_SFTP=1 builds) — the embedded server execs SFTPSERVER_PATH
	# (/tmp/sftp-server) for the subsystem, and multi-call dispatch keys off
	# basename(argv[0]), so a symlink named that way is all it takes. Works on
	# a read-only rootfs since /tmp is where this is staged, not $HERE.
	if [ ! -e /tmp/sftp-server ] && "$BIN" 2>&1 | grep -q "'sftp-server'"; then
		ln -sf "$BIN" /tmp/sftp-server 2>/dev/null \
			&& say 'staged sftp-server -> dropbearmulti at /tmp/sftp-server'
	fi

	# -F foreground, -E log to stderr; bind to the loopback host the tunnel
	# points at. Host key and the authorized key both come from the embedded
	# slots, so this works on a read-only rootfs with no /etc/dropbear.
	say "starting embedded server on $LHOST:$LPORT"
	"$BIN" dropbear -F -E -r /dev/null -p "$LHOST:$LPORT" >/tmp/$PROG-srv.log 2>&1 &
	SRV_PID=$!
fi

cleanup() {
	[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

# ------------------------------------------------------------------- tunnel
say "reverse tunnel: your-server:$RPORT -> device $LHOST:$LPORT, via $SERVER:$PORT"

connect() {
	# -y -y accept host key silently (first-run devices have no known_hosts);
	# -K 30 keepalive, -I 0 no idle timeout, -N no remote command.
	"$BIN" dbclient -y -y -K 30 -I 0 -N \
		-R "$RPORT:$LHOST:$LPORT" -p "$PORT" "$SERVER" </dev/null
}

if [ "$ONCE" -eq 1 ]; then
	connect
	exit $?
fi

DELAY=5
while :; do
	connect || true
	say "disconnected, reconnecting in ${DELAY}s"
	sleep "$DELAY"
	# Back off to a minute so a hard failure does not hammer the server,
	# but stay responsive to ordinary link flaps.
	[ "$DELAY" -lt 60 ] && DELAY=$((DELAY * 2)) || DELAY=60
done

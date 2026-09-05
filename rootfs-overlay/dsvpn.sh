#!/bin/sh
# sshd-tunnel DSVPN entrypoint, executed INSIDE the chroot.
#
#   /dsvpn.sh [options]
#
# Brings up a point-to-point DSVPN tunnel and prints a one-liner the device
# runs to fetch a matching static binary plus the key, and connect. Reached
# from the host as `./run --dsvpn`, which is what bind-mounts /dev/net/tun
# into the chroot; running this directly without that mount cannot work and
# says so.
#
# Why this exists next to /vpn.sh: that mode is OpenVPN, and needs an openvpn
# binary already installed on the device. Plenty of routers do not have one
# and cannot install one. DSVPN is a single ~100 kB static binary that this
# server hands over along with the key — nothing has to be present on the
# device beyond a shell, a downloader and /dev/net/tun.
#
# The trade-offs against the OpenVPN mode, stated plainly: DSVPN is TCP-only
# (so TCP-over-TCP, with the stalling that implies on a lossy link), it speaks
# its own protocol with its own Xoodoo-based crypto rather than TLS, and it is
# a much smaller and less scrutinised codebase. Reach for /vpn.sh when the
# device already has openvpn; reach for this when it does not.
#
# Environment:
#   SSHD_TUNNEL_IP   space-separated server addresses to advertise; when
#                    unset they are detected from the interfaces

set -eu

PROG='sshd-tunnel-dsvpn'
BODY='/usr/local/share/sshd-tunnel/dsvpn-body.sh'
BIN_DIR='/usr/local/share/sshd-tunnel/dsvpn'
WEB_ROOT='/srv/www'
RUNTIME_DIR='/run/sshd-tunnel-dsvpn'

PORT='1195'
HTTP_PORT=''
NET='10.9.1'

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

shquote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

usage() {
	cat <<EOF
Usage: /dsvpn.sh [options]

  Point-to-point DSVPN tunnel. The device gets $NET.2, this server is
  $NET.1, and everything on the device is reachable from here — unlike
  the reverse-SSH mode, which forwards one port.

  Unlike --vpn, the device needs no VPN software of its own: the matching
  static binary is served from here along with the key.

Options:
  --port <port>       TCP port for DSVPN (default: $PORT)
  --http <port>       port for the bootstrap HTTP server (default: <port>+1)
  --net <a.b.c>       /24 prefix for the tunnel addresses (default: $NET)
  -h, --help          this text
EOF
}

# --------------------------------------------------------------- argument parsing
while [ $# -gt 0 ]; do
	case "$1" in
		--port) [ $# -ge 2 ] || die '--port needs a value'; PORT="$2"; shift ;;
		--http) [ $# -ge 2 ] || die '--http needs a value'; HTTP_PORT="$2"; shift ;;
		--net)  [ $# -ge 2 ] || die '--net needs a value';  NET="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "unknown option: $1" ;;
	esac
	shift
done

case "$PORT" in
	''|*[!0-9]*) die "port must be a number, got: $PORT" ;;
esac
[ -n "$HTTP_PORT" ] || HTTP_PORT=$((PORT + 1))

VPN_SERVER="$NET.1"
VPN_CLIENT="$NET.2"

# ------------------------------------------------------------------ preflight
# Inside the chroot this path is a plain placeholder file until the host
# wrapper bind-mounts the real device over it, so the file type is the check.
[ -c /dev/net/tun ] || die 'no /dev/net/tun inside the chroot — start this with `./run --dsvpn`, not directly'
[ -f "$BODY" ] || die "missing $BODY"
[ -d "$BIN_DIR" ] || die "missing $BIN_DIR — this rootfs was built without the dsvpn binaries"

# The server needs a binary for its own architecture out of the same set it
# serves to devices, so there is exactly one build to trust and one to test.
case "$(uname -m)" in
	x86_64|amd64)   HOST_ARCH='x86_64' ;;
	i[3456]86)      HOST_ARCH='i686' ;;
	aarch64|arm64)  HOST_ARCH='aarch64' ;;
	armv7*|armv8l)  HOST_ARCH='armv7' ;;
	armv6*|armv5*|arm) HOST_ARCH='armv5' ;;
	*) die "no dsvpn build for this server's architecture: $(uname -m)" ;;
esac
DSVPN="$BIN_DIR/dsvpn-$HOST_ARCH"
[ -f "$DSVPN" ] || die "missing $DSVPN"
[ -x "$DSVPN" ] || die "$DSVPN is not executable"

rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

KEY="$RUNTIME_DIR/dsvpn.key"

DSVPN_PID=''
HTTPD_PID=''
TOKEN=''
cleanup() {
	[ -n "$DSVPN_PID" ] && kill "$DSVPN_PID" 2>/dev/null
	[ -n "$HTTPD_PID" ] && kill "$HTTPD_PID" 2>/dev/null
	[ -n "$TOKEN" ] && rm -rf "$WEB_ROOT/t/$TOKEN"
	rm -rf "$RUNTIME_DIR"
	return 0
}
trap cleanup EXIT INT TERM

# -------------------------------------------------------------------- the key
# dsvpn wants exactly 32 raw bytes; it has no keygen of its own.
dd if=/dev/urandom of="$KEY" bs=32 count=1 >/dev/null 2>&1 || die 'cannot generate a key'
[ "$(wc -c <"$KEY")" -eq 32 ] || die 'the generated key is not 32 bytes'
chmod 600 "$KEY"
log 'generated a fresh 32-byte key'

# ----------------------------------------------------------------- the server
# `auto` for the listen address and the interface name; the tunnel addresses
# are pinned so the one-liner can state them.
"$DSVPN" server "$KEY" auto "$PORT" auto "$VPN_SERVER" "$VPN_CLIENT" auto &
DSVPN_PID=$!

# Give it a moment to bind and create the interface, then make sure it did:
# a dead server here would otherwise be discovered only by the device.
sleep 2
kill -0 "$DSVPN_PID" 2>/dev/null || die 'dsvpn exited immediately — see the log above'
log "dsvpn listening on 0.0.0.0:$PORT/tcp (pid $DSVPN_PID)"

# ------------------------------------------------------------ server addresses
if [ -n "${SSHD_TUNNEL_IP:-}" ]; then
	SERVER_IPS="$SSHD_TUNNEL_IP"
else
	SERVER_IPS="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | tr '\n' ' ')"
fi
[ -n "$SERVER_IPS" ] || SERVER_IPS='<server-ip>'
PRIMARY_IP="${SERVER_IPS%% *}"
PRIMARY_IP="${PRIMARY_IP% }"

# --------------------------------------------------------------- HTTP bootstrap
TOKEN="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
TOKEN_DIR="$WEB_ROOT/t/$TOKEN"
rm -rf "$WEB_ROOT/t"
mkdir -p "$TOKEN_DIR/bin"

# The key travels over plain HTTP behind an unguessable token, exactly like
# the SSH client key in the other modes: the device has no TLS to rely on, and
# the key is regenerated on every start.
cp "$KEY" "$TOKEN_DIR/dsvpn.key"
chmod 644 "$TOKEN_DIR/dsvpn.key"

# Hard-linked rather than copied: seven binaries is about 800 kB, and this
# runs on every start. Falls back to a copy across filesystems.
#
# Nothing here may chmod them. A hard link shares the inode, so changing the
# mode of the link changes the mode of the binary in $BIN_DIR too — an earlier
# version dropped these to 644 to keep httpd from treating them as CGI, which
# quietly stripped the execute bit off the originals and made the *next* start
# fail with "missing dsvpn-x86_64" on a file that was plainly there. The chmod
# was not needed anyway: busybox httpd serves an executable file as static
# content, CGI being reserved for /cgi-bin and the handlers in httpd.conf.
for b in "$BIN_DIR"/dsvpn-*; do
	[ -f "$b" ] || continue
	ln "$b" "$TOKEN_DIR/bin/$(basename "$b")" 2>/dev/null || cp "$b" "$TOKEN_DIR/bin/"
done
SERVED_ARCHES="$(cd "$TOKEN_DIR/bin" && ls | sed 's/^dsvpn-//' | tr '\n' ' ')"

{
	printf '#!/bin/sh\n'
	printf '# %s bootstrap, generated %s\n' "$PROG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'SRV=%s\n'        "$(shquote "$PRIMARY_IP")"
	printf 'VPN_PORT=%s\n'   "$(shquote "$PORT")"
	printf 'HTTP_PORT=%s\n'  "$(shquote "$HTTP_PORT")"
	printf 'TOKEN=%s\n'      "$(shquote "$TOKEN")"
	printf 'VPN_LOCAL=%s\n'  "$(shquote "$VPN_CLIENT")"
	printf 'VPN_REMOTE=%s\n' "$(shquote "$VPN_SERVER")"
	printf '\n'
	cat "$BODY"
} > "$TOKEN_DIR/v"
chmod 644 "$TOKEN_DIR/v"

BOOTSTRAP_URL="http://$PRIMARY_IP:$HTTP_PORT/t/$TOKEN/v"

busybox-extras httpd -f -p "0.0.0.0:$HTTP_PORT" -h "$WEB_ROOT" &
HTTPD_PID=$!
log "bootstrap HTTP server listening on 0.0.0.0:$HTTP_PORT (pid $HTTPD_PID)"

# ----------------------------------------------------------------------- banner
cat <<EOF

  $PROG — point-to-point DSVPN tunnel
  ------------------------------------------------------------------
  dsvpn port       : $PORT/tcp (all interfaces)
  addresses        : $SERVER_IPS
  this server      : $VPN_SERVER
  the device       : $VPN_CLIENT
  key              : 32 random bytes, regenerated on every start
  binaries served  : $SERVED_ARCHES

  One-liner for the device (needs nothing installed there):
    wget -O- $BOOTSTRAP_URL | sh

  Or with curl:
    curl -fsSL $BOOTSTRAP_URL | sh

  It detects the architecture, pulls the matching static binary and the
  key from here, checks the binary runs on that CPU, and connects.

  Once it connects, reach the device from here at $VPN_CLIENT, e.g.:
    ping $VPN_CLIENT
    ssh root@$VPN_CLIENT

  If that stays silent, or comes back as "port unreachable", while the
  tunnel is clearly up, it is the device's own firewall and not this end:
  OpenWrt rejects input on an interface that belongs to no firewall zone.
  Traffic the device starts still works, so test with a ping the other way
  first. On OpenWrt:
    uci add firewall zone && uci set firewall.@zone[-1].name=vpn \\
      && uci set firewall.@zone[-1].input=ACCEPT \\
      && uci set firewall.@zone[-1].device=tun0 && uci commit firewall \\
      && /etc/init.d/firewall reload

  Nothing else on the device is touched: no sysctl, no firewall rule, no
  change to the routing table. Ctrl-C here stops the tunnel and revokes
  the one-liner; killing dsvpn on the device removes its tun interface and
  leaves nothing behind.

EOF

wait "$DSVPN_PID"

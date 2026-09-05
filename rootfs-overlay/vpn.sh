#!/bin/sh
# sshd-tunnel VPN entrypoint, executed INSIDE the chroot.
#
#   /vpn.sh [options]
#
# Brings up a point-to-point OpenVPN tunnel and prints a one-liner the device
# runs to fetch its key and connect. Reached from the host as `./run --vpn`,
# which is what bind-mounts /dev/net/tun into the chroot; running this
# directly without that mount cannot work and says so.
#
# The reverse-SSH mode (/run.sh) forwards one port. This forwards everything:
# the device becomes an address the server can reach directly.
#
# Environment:
#   SSHD_TUNNEL_IP   space-separated server addresses to advertise; when
#                    unset they are detected from the interfaces

set -eu

PROG='sshd-tunnel-vpn'
BODY='/usr/local/share/sshd-tunnel/vpn-body.sh'
WEB_ROOT='/srv/www'
RUNTIME_DIR='/run/sshd-tunnel-vpn'

PORT='1194'
HTTP_PORT=''
NET='10.9.0'
# udp is right for a VPN; tcp exists for networks that only let TCP out, and
# for tunnelling the whole thing through something else.
PROTO='udp'
# Stated explicitly rather than negotiated: static-key mode has no handshake
# to negotiate in, 2.6 refuses to assume a default there, and 2.4 never had
# negotiation at all. AES-256-CBC + SHA256 is the pair every one of them has.
CIPHER='AES-256-CBC'
AUTH='SHA256'

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

shquote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

usage() {
	cat <<EOF
Usage: /vpn.sh [options]

  Point-to-point OpenVPN tunnel with a static key. The device gets
  $NET.2, this server is $NET.1, and everything on the device is
  reachable from here — unlike the reverse-SSH mode, which forwards one port.

Options:
  --port <port>       port for OpenVPN (default: $PORT)
  --proto <udp|tcp>   transport (default: $PROTO; tcp for networks that
                      only pass TCP)
  --http <port>       port for the bootstrap HTTP server (default: <port>+1)
  --net <a.b.c>       /24 prefix for the tunnel addresses (default: $NET)
  --cipher <name>     data cipher (default: $CIPHER)
  --auth <name>       HMAC digest (default: $AUTH)
  -h, --help          this text
EOF
}

# --------------------------------------------------------------- argument parsing
while [ $# -gt 0 ]; do
	case "$1" in
		--port)   [ $# -ge 2 ] || die '--port needs a value';   PORT="$2"; shift ;;
		--proto)  [ $# -ge 2 ] || die '--proto needs a value';  PROTO="$2"; shift ;;
		--http)   [ $# -ge 2 ] || die '--http needs a value';   HTTP_PORT="$2"; shift ;;
		--net)    [ $# -ge 2 ] || die '--net needs a value';    NET="$2"; shift ;;
		--cipher) [ $# -ge 2 ] || die '--cipher needs a value'; CIPHER="$2"; shift ;;
		--auth)   [ $# -ge 2 ] || die '--auth needs a value';   AUTH="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "unknown option: $1" ;;
	esac
	shift
done

case "$PORT" in
	''|*[!0-9]*) die "port must be a number, got: $PORT" ;;
esac
[ -n "$HTTP_PORT" ] || HTTP_PORT=$((PORT + 1))

# openvpn spells the two ends of a TCP tunnel differently; udp is the same
# word on both sides.
case "$PROTO" in
	udp) SRV_PROTO='udp';        CLI_PROTO='udp' ;;
	tcp) SRV_PROTO='tcp-server'; CLI_PROTO='tcp-client' ;;
	*)   die "--proto must be udp or tcp, got: $PROTO" ;;
esac

VPN_SERVER="$NET.1"
VPN_CLIENT="$NET.2"

# ------------------------------------------------------------------ preflight
# Inside the chroot this path is a plain placeholder file until the host
# wrapper bind-mounts the real device over it, so the file type is the check.
[ -c /dev/net/tun ] || die 'no /dev/net/tun inside the chroot — start this with `./run --vpn`, not directly'
command -v openvpn >/dev/null 2>&1 || die 'openvpn is missing from this rootfs'
[ -f "$BODY" ] || die "missing $BODY"

rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

KEY="$RUNTIME_DIR/static.key"
CONF="$RUNTIME_DIR/server.conf"

OPENVPN_PID=''
HTTPD_PID=''
TOKEN=''
cleanup() {
	[ -n "$OPENVPN_PID" ] && kill "$OPENVPN_PID" 2>/dev/null
	[ -n "$HTTPD_PID" ] && kill "$HTTPD_PID" 2>/dev/null
	[ -n "$TOKEN" ] && rm -rf "$WEB_ROOT/t/$TOKEN"
	rm -rf "$RUNTIME_DIR"
	return 0
}
trap cleanup EXIT INT TERM

# -------------------------------------------------------------------- the key
# 2.6 spells this `--genkey secret FILE`; 2.4/2.5 want `--genkey --secret FILE`.
if ! openvpn --genkey secret "$KEY" >/dev/null 2>&1; then
	openvpn --genkey --secret "$KEY" >/dev/null 2>&1 \
		|| die 'openvpn --genkey failed'
fi
chmod 600 "$KEY"
log 'generated a fresh static key'

# ----------------------------------------------------------------- the server
# OpenVPN 2.7 refuses to start a non-TLS (static key) tunnel unless this is
# passed, and 2.8 drops the mode entirely. It goes only in the *server*
# config: this rootfs pins the version, whereas the devices run whatever they
# run — 2.4 and 2.5 are common out there and would reject the unknown option.
# Probed rather than assumed, so an older openvpn in the rootfs still works.
# The probe has to actually pass the option: 2.7 accepts it but does not list
# it in --help, so grepping the help text finds nothing and silently guesses
# wrong.
DEPRECATED_OPT=''
if openvpn --allow-deprecated-insecure-static-crypto --version >/dev/null 2>&1; then
	DEPRECATED_OPT='allow-deprecated-insecure-static-crypto'
fi

{
	cat <<EOF
dev tun
proto $SRV_PROTO
port $PORT
ifconfig $VPN_SERVER $VPN_CLIENT
secret $KEY
cipher $CIPHER
auth $AUTH
keepalive 10 60
persist-tun
verb 3
EOF
	if [ -n "$DEPRECATED_OPT" ]; then printf '%s\n' "$DEPRECATED_OPT"; fi
} > "$CONF"

openvpn --config "$CONF" &
OPENVPN_PID=$!

# Give it a moment to bind and create the interface, then make sure it did:
# a dead server here would otherwise be discovered only by the device.
sleep 2
kill -0 "$OPENVPN_PID" 2>/dev/null || die 'openvpn exited immediately — see the log above'
log "openvpn listening on 0.0.0.0:$PORT/$PROTO (pid $OPENVPN_PID)"

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
mkdir -p "$TOKEN_DIR"

# The static key travels over plain HTTP behind an unguessable token, exactly
# like the SSH client key in the other mode: the device has no TLS to rely on,
# and the key is regenerated on every start.
cp "$KEY" "$TOKEN_DIR/static.key"
chmod 644 "$TOKEN_DIR/static.key"

{
	printf '#!/bin/sh\n'
	printf '# %s bootstrap, generated %s\n' "$PROG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'SRV=%s\n'        "$(shquote "$PRIMARY_IP")"
	printf 'VPN_PORT=%s\n'   "$(shquote "$PORT")"
	printf 'HTTP_PORT=%s\n'  "$(shquote "$HTTP_PORT")"
	printf 'TOKEN=%s\n'      "$(shquote "$TOKEN")"
	printf 'VPN_LOCAL=%s\n'  "$(shquote "$VPN_CLIENT")"
	printf 'VPN_REMOTE=%s\n' "$(shquote "$VPN_SERVER")"
	printf 'PROTO=%s\n'      "$(shquote "$CLI_PROTO")"
	printf 'CIPHER=%s\n'     "$(shquote "$CIPHER")"
	printf 'AUTH=%s\n'       "$(shquote "$AUTH")"
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

  $PROG — point-to-point OpenVPN tunnel
  ------------------------------------------------------------------
  openvpn port     : $PORT/$PROTO (all interfaces)
  addresses        : $SERVER_IPS
  this server      : $VPN_SERVER
  the device       : $VPN_CLIENT
  cipher / auth    : $CIPHER / $AUTH
  static key       : regenerated on every start

  One-liner for the device (needs openvpn installed there):
    wget -O- $BOOTSTRAP_URL | sh

  Or with curl:
    curl -fsSL $BOOTSTRAP_URL | sh

  Once it connects, reach the device from here at $VPN_CLIENT, e.g.:
    ping $VPN_CLIENT
    ssh root@$VPN_CLIENT

  If that stays silent while the tunnel is clearly up, it is the device's
  own firewall, not this end: OpenWrt drops input on an interface that
  belongs to no firewall zone. Traffic the device starts still works, so
  test with a ping the other way first. On OpenWrt:
    uci add firewall zone && uci set firewall.@zone[-1].name=vpn \\
      && uci set firewall.@zone[-1].input=ACCEPT \\
      && uci set firewall.@zone[-1].device=tun0 && uci commit firewall \\
      && /etc/init.d/firewall reload

  Ctrl-C stops the tunnel and revokes the one-liner.

EOF

wait "$OPENVPN_PID"

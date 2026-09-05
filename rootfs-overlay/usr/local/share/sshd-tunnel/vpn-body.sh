# Body of the VPN bootstrap script served over HTTP. /vpn.sh prepends a header
# of shell-quoted variable assignments and serves the concatenation; this file
# contains no placeholders, so no value ever needs sed-escaping.
#
# Expected variables: SRV VPN_PORT HTTP_PORT TOKEN VPN_LOCAL VPN_REMOTE PROTO CIPHER AUTH
# Overridable from the environment: DIR
#
# Target: busybox ash on a device from around 2014. Nothing here may rely on
# bash, on GNU coreutils flags, or on TLS.

set -u

PROG='sshd-tunnel-vpn'
say() { printf '%s: %s\n' "$PROG" "$*" >&2; }

have() {
	command -v "$1" >/dev/null 2>&1 && return 0
	which "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------- openvpn present?
# The whole point of failing loudly here: without this the device would get a
# config it can do nothing with, and the only symptom would be silence.
if ! have openvpn; then
	say 'this device has no openvpn binary'
	say 'install it first (OpenWrt: opkg install openvpn-openssl,'
	say 'Debian/Ubuntu: apt install openvpn) and re-run this one-liner'
	exit 1
fi

DIR="${DIR:-/tmp/sshd-tunnel-vpn}"
mkdir -p "$DIR" || { say "cannot create $DIR"; exit 1; }
chmod 700 "$DIR" 2>/dev/null

KEY="$DIR/static.key"
CONF="$DIR/client.conf"

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

# ------------------------------------------------------------------- the key
if ! fetch "http://$SRV:$HTTP_PORT/t/$TOKEN/static.key" "$KEY"; then
	say "cannot fetch http://$SRV:$HTTP_PORT/t/$TOKEN/static.key"
	exit 1
fi
[ -s "$KEY" ] || { say 'the fetched key is empty'; exit 1; }
chmod 600 "$KEY" 2>/dev/null
say 'static key retrieved'

# ---------------------------------------------------------------- the config
# Point-to-point static-key mode: no PKI, no TLS handshake, works with every
# openvpn since the 2.x days — which is the point, given what these devices
# tend to be running. `cipher`/`auth` are stated explicitly because 2.6
# refuses to guess them in this mode while 2.4 has no negotiation at all.
cat > "$CONF" <<EOF
remote $SRV $VPN_PORT
proto $PROTO
dev tun
ifconfig $VPN_LOCAL $VPN_REMOTE
secret $KEY
cipher $CIPHER
auth $AUTH
keepalive 10 60
persist-key
persist-tun
resolv-retry infinite
nobind
verb 3
EOF
chmod 600 "$CONF" 2>/dev/null

say "connecting to $SRV:$VPN_PORT ($PROTO) — this device becomes $VPN_LOCAL, the server is $VPN_REMOTE"
say "config: $CONF"

# openvpn keeps the tunnel up by itself (keepalive + ping-restart), so there is
# no reconnect loop around it the way the SSH bootstrap needs one.
exec openvpn --config "$CONF"

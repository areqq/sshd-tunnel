#!/bin/sh
# Every value --key-type accepts must survive the whole chain: ssh-keygen on
# the server, dropbearconvert from 2014, authentication, and a byte arriving
# through the forward. Anything less proves nothing — a key that converts but
# cannot authenticate is still useless on the device.
#
# ed25519 and dss are deliberately absent and asserted to be rejected: Dropbear
# gained ed25519 only in 2020.79 (and it has no PEM representation for a 2014
# dropbearconvert), while OpenSSH 10 removed ssh-dss from the server entirely.
set -eu

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_NAME='client key types'
. tests/lib.sh

require python3 od sed timeout ssh-keygen
require_dropbear_2014

KEY_TYPES='rsa2048 rsa3072 rsa4096 ecdsa256 ecdsa384 ecdsa521'
REJECTED_TYPES='ed25519 dss rsa1024 ecdsa512 nonsense'

DEVPORT="$(free_port)"

cleanup() {
	[ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null
	stop_server
	stop_endpoint
	rm -rf "$TEST_TMP"
}
trap cleanup EXIT INT TERM HUP

start_endpoint "$DEVPORT"
wait_for_port "$DEVPORT" 10 || { fail 'the stand-in device endpoint did not start'; summary; exit 1; }

for key_type in $KEY_TYPES; do
	PORT="$(free_port)"
	RPORT="$(free_port)"

	start_server "$PORT" --no-http --key-type "$key_type"
	if ! wait_for_port "$PORT" 30; then
		fail "$key_type: sshd did not start"
		server_log | sed 's/^/          | /'
		stop_server
		continue
	fi

	check "$key_type: the banner names the key type" "($key_type, PEM)" "$(server_log)"

	if ! extract_client_key "$TEST_TMP/id"; then
		fail "$key_type: no private key printed"
		stop_server
		continue
	fi

	if ! dropbearconvert_2014 openssh dropbear "$TEST_TMP/id" "$TEST_TMP/id.db" \
		>"$TEST_TMP/convert.log" 2>&1
	then
		fail "$key_type: dropbearconvert 2014 could not read the key"
		sed 's/^/          | /' "$TEST_TMP/convert.log"
		stop_server
		continue
	fi

	HOME="$TEST_TMP" "$DBCLIENT" -y -y -K 30 -I 0 -N \
		-i "$TEST_TMP/id.db" \
		-R "$RPORT:127.0.0.1:$DEVPORT" \
		-p "$PORT" tcp@127.0.0.1 >"$TEST_TMP/dbclient.log" 2>&1 &
	TUNNEL_PID=$!

	if wait_for_port "$RPORT" 30; then
		check "$key_type: bytes traverse the tunnel" "$ECHO_TOKEN" "$(read_through_tunnel "$RPORT")"
	else
		fail "$key_type: the reverse listener never appeared"
		sed 's/^/          | /' "$TEST_TMP/dbclient.log"
	fi

	kill "$TUNNEL_PID" 2>/dev/null || true
	TUNNEL_PID=''
	stop_server
	rm -f "$TEST_TMP/id" "$TEST_TMP/id.db"
done

# ------------------------------------------------------- unsupported types
for key_type in $REJECTED_TYPES; do
	PORT="$(free_port)"
	start_server "$PORT" --no-http --key-type "$key_type"
	wait "$SERVER_PID" 2>/dev/null || true
	SERVER_PID=''
	if port_in_use "$PORT"; then
		fail "--key-type $key_type started a server instead of being rejected"
	else
		check "--key-type $key_type is rejected" 'unknown --key-type' "$(server_log)"
	fi
done

summary

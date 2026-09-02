#!/bin/sh
# End-to-end: a Dropbear 2014 client authenticates with the key printed at
# startup, opens a reverse forward, and bytes actually travel through it.
set -eu

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_NAME='tunnel, key auth'
. tests/lib.sh

require python3 od sed timeout
require_dropbear_2014

PORT="$(free_port)"
RPORT="$(free_port)"
DEVPORT="$(free_port)"

cleanup() {
	[ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null
	stop_server
	stop_endpoint
	rm -rf "$TEST_TMP"
}
trap cleanup EXIT INT TERM HUP

printf '%s: sshd on %s, reverse listener %s, device endpoint %s\n' \
	"$TEST_NAME" "$PORT" "$RPORT" "$DEVPORT"

start_endpoint "$DEVPORT"
wait_for_port "$DEVPORT" 10 || { fail 'the stand-in device endpoint did not start'; summary; exit 1; }

start_server "$PORT" --no-http
if ! wait_for_port "$PORT" 30; then
	fail 'sshd did not start'
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi
ok "sshd is listening on $PORT"

check 'banner reports key-only auth' 'auth mode        : key only' "$(server_log)"

if extract_client_key "$TEST_TMP/id"; then
	ok 'a private key was printed at startup'
else
	fail 'no private key in the startup output'
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi

# The conversion is done by the 2014 tool, so a format the old build cannot
# read would fail here rather than silently at connect time.
if dropbearconvert_2014 openssh dropbear "$TEST_TMP/id" "$TEST_TMP/id.db" >"$TEST_TMP/convert.log" 2>&1; then
	ok 'dropbearconvert 2014 accepts the generated PEM key'
else
	fail 'dropbearconvert 2014 could not read the generated key'
	sed 's/^/          | /' "$TEST_TMP/convert.log"
fi

HOME="$TEST_TMP" dbclient_2014 -y -y -K 30 -I 0 -N \
	-i "$TEST_TMP/id.db" \
	-R "$RPORT:127.0.0.1:$DEVPORT" \
	-p "$PORT" tcp@127.0.0.1 >"$TEST_TMP/dbclient.log" 2>&1 &
TUNNEL_PID=$!

if wait_for_port "$RPORT" 30; then
	ok "the reverse listener appeared on $RPORT"
else
	fail 'the reverse listener never appeared'
	sed 's/^/          | /' "$TEST_TMP/dbclient.log"
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi

if port_bound_wildcard "$RPORT"; then
	ok 'the reverse listener is bound on all interfaces (GatewayPorts yes)'
else
	fail 'the reverse listener is not bound on 0.0.0.0'
fi

check 'bytes traverse the tunnel' "$ECHO_TOKEN" "$(read_through_tunnel "$RPORT")"

# ------------------------------------------------------- the wrapper cleans up
# A bind mount left behind survives the process, makes the rootfs impossible to
# delete, and breaks the next build — so this is asserted rather than assumed.
kill "$TUNNEL_PID" 2>/dev/null || true
TUNNEL_PID=''
$SUDO kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
sleep 2
LEFTOVER="$(mounts_under_rootfs)"
SERVER_PID=''
if [ -z "$LEFTOVER" ]; then
	ok 'the wrapper unmounted /proc and /dev on exit'
else
	fail 'the wrapper left mounts behind'
	printf '%s\n' "$LEFTOVER" | sed 's/^/          | /'
	for leftover in $LEFTOVER; do
		$SUDO umount -l "$leftover" 2>/dev/null || true
	done
fi

summary

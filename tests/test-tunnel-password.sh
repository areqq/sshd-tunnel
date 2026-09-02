#!/bin/sh
# End-to-end: password-only mode. Dropbear takes the password from
# DROPBEAR_PASSWORD, which is what makes the wget-piped bootstrap possible on
# a device with no way to store a key.
set -eu

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_NAME='tunnel, password auth'
. tests/lib.sh

require python3 od sed timeout
require_dropbear_2014

PORT="$(free_port)"
RPORT="$(free_port)"
DEVPORT="$(free_port)"
# Deliberately awkward: quotes and a backslash would break naive substitution
# into either the config or the generated bootstrap script.
PASSWORD="p'a\"s\$s\\w0rd!"

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

start_server "$PORT" "$PASSWORD" --no-http
if ! wait_for_port "$PORT" 30; then
	fail 'sshd did not start'
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi
ok "sshd is listening on $PORT"

check 'banner reports password-only auth' 'auth mode        : password only' "$(server_log)"
check_absent 'no private key is printed in password mode' 'PRIVATE KEY-----' "$(server_log)"

HOME="$TEST_TMP" DROPBEAR_PASSWORD="$PASSWORD" dbclient_2014 -y -y -K 30 -I 0 -N \
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

check 'bytes traverse the tunnel' "$ECHO_TOKEN" "$(read_through_tunnel "$RPORT")"

# A key must not be an alternative route in while password mode is active.
ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -f "$TEST_TMP/other" 2>/dev/null
dropbearconvert_2014 openssh dropbear "$TEST_TMP/other" "$TEST_TMP/other.db" >/dev/null 2>&1 || true
KEY_ATTEMPT="$(HOME="$TEST_TMP" timeout 20 "$DBCLIENT" -y -y -N -i "$TEST_TMP/other.db" \
	-R "$(free_port):127.0.0.1:$DEVPORT" -p "$PORT" tcp@127.0.0.1 2>&1 || true)"
check_absent 'public keys are rejected in password mode' "$ECHO_TOKEN" "$KEY_ATTEMPT"
if printf '%s' "$KEY_ATTEMPT" | grep -qiE 'authentication|password|denied'; then
	ok 'the server refused key authentication'
else
	fail 'unclear whether key authentication was refused'
	printf '%s\n' "$KEY_ATTEMPT" | sed 's/^/          | /'
fi

summary

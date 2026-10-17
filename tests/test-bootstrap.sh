#!/bin/sh
# The HTTP bootstrap path: fetch the generated script over plain HTTP, run it
# with `sh`, and end up with a working tunnel — the `wget -O- ... | sh` flow a
# 2014 device would use.
set -eu

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_NAME='http bootstrap'
. tests/lib.sh

require python3 od sed timeout curl pkill
require_dropbear_2014

PORT="$(free_port)"
HTTP_PORT="$(free_port)"
RPORT="$(free_port)"
DEVPORT="$(free_port)"

cleanup() {
	[ -n "${BOOTSTRAP_PID:-}" ] && kill "$BOOTSTRAP_PID" 2>/dev/null
	stop_server
	stop_endpoint
	rm -rf "$TEST_TMP"
}
trap cleanup EXIT INT TERM HUP

printf '%s: sshd %s, http %s, reverse %s, device %s\n' \
	"$TEST_NAME" "$PORT" "$HTTP_PORT" "$RPORT" "$DEVPORT"

start_endpoint "$DEVPORT"
wait_for_port "$DEVPORT" 10 || { fail 'the stand-in device endpoint did not start'; summary; exit 1; }

start_server "$PORT" --http "$HTTP_PORT" --expose "$RPORT:127.0.0.1:$DEVPORT"
if ! wait_for_port "$PORT" 30; then
	fail 'sshd did not start'
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi
wait_for_port "$HTTP_PORT" 20 || fail 'the bootstrap HTTP server did not start'

URL="$(extract_bootstrap_url)"
if [ -n "$URL" ]; then
	ok "the banner advertises $URL"
else
	fail 'no bootstrap URL in the startup output'
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi

BASE="${URL%/t/*}"

# ------------------------------------------------------------- token is required
for path in '/' '/t/' '/t/0000000000000000000000000000000/b' '/srv' '/etc/passwd'; do
	CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE$path" || echo 000)"
	case "$CODE" in
		200) fail "$path returned 200 without a valid token" ;;
		*)   ok "$path is not served (HTTP $CODE)" ;;
	esac
done

# ---------------------------------------------------------------- fetch and lint
curl -fsS -o "$TEST_TMP/b" "$URL" || { fail 'cannot fetch the bootstrap script'; summary; exit 1; }
ok 'the bootstrap script downloads'

if sh -n "$TEST_TMP/b"; then
	ok 'the bootstrap script is valid POSIX shell'
else
	fail 'the bootstrap script does not parse'
fi
check 'it targets the tcp account' 'tcp@' "$(cat "$TEST_TMP/b")"
check 'it carries the reverse mapping' "$RPORT" "$(cat "$TEST_TMP/b")"

# --------------------------------------------------------------------- run it
# PATH is prepended so the script picks the 2014 dbclient, exactly as it would
# find the device's own build.
# As a terminal would run it (see start_detached), so Ctrl-C can be
# simulated below: delivered to the script and its dbclient together.
PATH="$DROPBEAR_DIR:$PATH" HOME="$TEST_TMP" TMPDIR="$TEST_TMP" \
	start_detached sh "$TEST_TMP/b" >"$TEST_TMP/bootstrap.log" 2>&1
BOOTSTRAP_PID=$DEVICE_PID

if wait_for_port "$RPORT" 40; then
	ok "the bootstrap script brought up the reverse listener on $RPORT"
else
	fail 'the bootstrap script did not establish the tunnel'
	sed 's/^/          | /' "$TEST_TMP/bootstrap.log"
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi

check 'bytes traverse the bootstrapped tunnel' "$ECHO_TOKEN" "$(read_through_tunnel "$RPORT")"
check 'the script reports which client it chose' 'using dbclient' "$(cat "$TEST_TMP/bootstrap.log")"

# Ctrl-C must end the script. An earlier version's INT trap deleted the key
# and returned, so the loop went on retrying without it and could not be
# stopped from the keyboard at all.
interrupt_group "$BOOTSTRAP_PID"
if waited="$(wait_for_exit "$BOOTSTRAP_PID" 10)"; then
	ok "Ctrl-C ends the bootstrap script (after ${waited}s)"
else
	fail 'the bootstrap script is still running 10s after Ctrl-C'
	pkill -9 -g "$BOOTSTRAP_PID" 2>/dev/null || true
fi
wait "$BOOTSTRAP_PID" 2>/dev/null || true
check 'it says so' 'interrupted' "$(cat "$TEST_TMP/bootstrap.log")"
check_absent 'it does not retry without the key' 'Failed loading keyfile' "$(cat "$TEST_TMP/bootstrap.log")"
if ls -d "$TEST_TMP"/sshd-tunnel.* >/dev/null 2>&1; then
	fail 'the work directory with the key survived Ctrl-C'
else
	ok 'the work directory with the key is removed on Ctrl-C'
fi
BOOTSTRAP_PID=''

# ----------------------------------------------------- the same flow with a password
stop_server
RPORT2="$(free_port)"
PORT2="$(free_port)"
HTTP_PORT2="$(free_port)"
start_server "$PORT2" 'bootstrap-pw' --http "$HTTP_PORT2" --expose "$RPORT2:127.0.0.1:$DEVPORT"
wait_for_port "$PORT2" 30 || { fail 'sshd did not start in password mode'; summary; exit 1; }
wait_for_port "$HTTP_PORT2" 20 || fail 'the bootstrap HTTP server did not start in password mode'

URL2="$(extract_bootstrap_url)"
curl -fsS -o "$TEST_TMP/b2" "$URL2" || { fail 'cannot fetch the password-mode bootstrap'; summary; exit 1; }
check_absent 'the password-mode bootstrap embeds no private key' 'PRIVATE KEY-----' "$(cat "$TEST_TMP/b2")"
check 'it uses DROPBEAR_PASSWORD' 'DROPBEAR_PASSWORD' "$(cat "$TEST_TMP/b2")"

PATH="$DROPBEAR_DIR:$PATH" HOME="$TEST_TMP" TMPDIR="$TEST_TMP" \
	sh "$TEST_TMP/b2" >"$TEST_TMP/bootstrap2.log" 2>&1 &
BOOTSTRAP_PID=$!

if wait_for_port "$RPORT2" 40; then
	check 'bytes traverse the password-mode tunnel' "$ECHO_TOKEN" "$(read_through_tunnel "$RPORT2")"
else
	fail 'the password-mode bootstrap did not establish the tunnel'
	sed 's/^/          | /' "$TEST_TMP/bootstrap2.log"
	server_log | sed 's/^/          | /'
fi

summary

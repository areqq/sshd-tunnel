#!/bin/sh
# The default listener layout: sshd and the bootstrap HTTP server behind sslh
# on one public port, both on loopback behind it. Asserted with the clients
# that matter -- a 2014 Dropbear through the port for the tunnel, wget/curl
# through the same port for the script -- plus the things that would go wrong
# silently: sshd or httpd reachable on a public port of their own, or the
# ssh probe falling back to its timeout.
set -eu

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_NAME='single port'
. tests/lib.sh

require python3 od sed timeout curl ssh ssh-keyscan
require_dropbear_2014

PORT="$(free_port)"
RPORT="$(free_port)"
DEVPORT="$(free_port)"
# The loopback ports the layout derives; they must be free for the test.
SSHD_PORT=$((PORT + 1))
HTTP_PORT=$((PORT + 2))
port_in_use "$SSHD_PORT" || port_in_use "$HTTP_PORT" && { PORT="$(free_port)"; SSHD_PORT=$((PORT + 1)); HTTP_PORT=$((PORT + 2)); }

cleanup() {
	[ -n "${BOOTSTRAP_PID:-}" ] && kill "$BOOTSTRAP_PID" 2>/dev/null
	stop_server
	stop_endpoint
	rm -rf "$TEST_TMP"
}
trap cleanup EXIT INT TERM HUP

printf '%s: port %s (loopback sshd %s, httpd %s), reverse %s, device %s\n' \
	"$TEST_NAME" "$PORT" "$SSHD_PORT" "$HTTP_PORT" "$RPORT" "$DEVPORT"

start_endpoint "$DEVPORT"
wait_for_port "$DEVPORT" 10 || { fail 'the stand-in device endpoint did not start'; summary; exit 1; }

start_server "$PORT" --expose "$RPORT:127.0.0.1:$DEVPORT"
if ! wait_for_port "$PORT" 30; then
	fail 'nothing is listening on the public port'
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi
wait_for_text "$SERVER_LOG" 'sslh listening' 20 || fail 'sslh did not report listening'
wait_for_text "$SERVER_LOG" 'Server listening on 127.0.0.1' 20 || fail 'sshd did not report listening on loopback'

# ------------------------------------------------------------- the listeners
if port_bound_wildcard "$PORT"; then ok "the public port $PORT is bound on all interfaces"; else fail "port $PORT is not bound on 0.0.0.0"; fi
if port_bound_wildcard "$SSHD_PORT"; then fail "sshd is reachable on a public port ($SSHD_PORT)"; else ok "sshd ($SSHD_PORT) is not bound on a public interface"; fi
if port_bound_wildcard "$HTTP_PORT"; then fail "httpd is reachable on a public port ($HTTP_PORT)"; else ok "httpd ($HTTP_PORT) is not bound on a public interface"; fi
port_in_use "$SSHD_PORT" && ok 'sshd listens on loopback' || fail 'sshd is not listening on its loopback port'
port_in_use "$HTTP_PORT" && ok 'httpd listens on loopback' || fail 'httpd is not listening on its loopback port'

check 'the banner says the port is shared' 'share it' "$(server_log)"
check 'the rendered config exempts loopback from per-source penalties' 'PerSourcePenaltyExemptList' \
	"$($SUDO cat "$INSTALL_DIR/rootfs/etc/ssh/sshd_config.active")"

# ----------------------------------------------------------- SSH through sslh
# A real client sends its "SSH-2.0-" line at once, so the probe matches
# without the two-second timeout: a whole key exchange plus a refused
# authentication comes back well under that. (ssh-keyscan is not a real
# client here: it waits for the server's banner and so always takes the
# timeout path; it is used below for the host key only.)
START="$(date +%s%N 2>/dev/null || date +%s)"
OUT="$(timeout 15 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-p "$PORT" tcp@127.0.0.1 true 2>&1 || true)"
END="$(date +%s%N 2>/dev/null || date +%s)"
check 'an OpenSSH client reaches sshd through the public port' 'Permission denied' "$OUT"
case "$START$END" in
	*[!0-9]*) ;;
	*)
		MS=$(( (END - START) / 1000000 ))
		if [ "$MS" -lt 1500 ]; then
			ok "the SSH probe matched without waiting for the timeout (${MS} ms)"
		else
			fail "the SSH exchange took ${MS} ms: sslh is falling back to the timeout"
		fi
		;;
esac
SCANNED="$(timeout 20 ssh-keyscan -t rsa -p "$PORT" 127.0.0.1 2>/dev/null | head -1)"
if [ -n "$SCANNED" ]; then
	ok 'the sshd host key comes back through the public port'
else
	fail 'no host key through the public port'
fi
BANNER_FP="$(server_log | sed -n 's/.*host key SHA256  : //p' | head -1)"
SCANNED_FP="$(printf '%s\n' "$SCANNED" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
if [ -n "$BANNER_FP" ] && [ "$BANNER_FP" = "$SCANNED_FP" ]; then
	ok 'it is the host key the banner announced'
else
	fail "host key mismatch through sslh: banner $BANNER_FP, wire ${SCANNED_FP:-none}"
fi

# ---------------------------------------------------------- HTTP through sslh
URL="$(extract_bootstrap_url)"
if [ -n "$URL" ]; then
	ok "the banner advertises $URL"
	check 'the advertised URL uses the shared port' ":$PORT/t/" "$URL"
else
	fail 'no bootstrap URL in the startup output'
	summary
	exit 1
fi
BASE="${URL%/t/*}"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/t/0000000000000000000000000000000/b" || echo 000)"
case "$CODE" in
	200) fail 'a wrong token is served through sslh' ;;
	*)   ok "a wrong token is refused through sslh (HTTP $CODE)" ;;
esac
curl -fsS -o "$TEST_TMP/b" "$URL" || { fail 'cannot fetch the bootstrap script through the public port'; summary; exit 1; }
ok 'the bootstrap script downloads through the public port'
# sslh-fork died after its first connection in this chroot; a demultiplexer
# that survives exactly one request would pass everything above.
FETCHED=0
for i in 1 2 3 4 5 6; do
	curl -fsS -m 10 -o /dev/null "$URL" && FETCHED=$((FETCHED + 1))
done
if [ "$FETCHED" -eq 6 ]; then
	ok 'six more fetches in a row all succeed (sslh survives its connections)'
else
	fail "only $FETCHED of 6 repeated fetches succeeded: sslh is dying on connections"
fi
check 'the script dials the shared port for SSH' "SSH_PORT='$PORT'" "$(cat "$TEST_TMP/b")"
check 'the script dials the shared port for HTTP' "HTTP_PORT='$PORT'" "$(cat "$TEST_TMP/b")"

# --------------------------------------------- the 2014 client, end to end
PATH="$DROPBEAR_DIR:$PATH" HOME="$TEST_TMP" TMPDIR="$TEST_TMP" \
	sh "$TEST_TMP/b" >"$TEST_TMP/bootstrap.log" 2>&1 &
BOOTSTRAP_PID=$!
if wait_for_port "$RPORT" 40; then
	ok "the 2014 client brought the tunnel up through sslh (listener on $RPORT)"
else
	fail 'the 2014 client did not establish the tunnel through sslh'
	sed 's/^/          | /' "$TEST_TMP/bootstrap.log"
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi
check 'bytes traverse the tunnel' "$ECHO_TOKEN" "$(read_through_tunnel "$RPORT")"

# ------------------------------------------------------ the two-port layout
# --http <port> is the older layout and must still work: sshd public on
# <port>, httpd public on its own port, no sslh.
kill "$BOOTSTRAP_PID" 2>/dev/null || true
BOOTSTRAP_PID=''
stop_server
PORT2="$(free_port)"
HTTP2="$(free_port)"
start_server "$PORT2" --http "$HTTP2" --expose "$RPORT:127.0.0.1:$DEVPORT"
wait_for_port "$PORT2" 30 || { fail 'the two-port layout did not start'; summary; exit 1; }
wait_for_port "$HTTP2" 20 || fail 'the two-port layout did not start httpd'
check_absent 'the two-port layout starts no sslh' 'sslh listening' "$(server_log)"
port_bound_wildcard "$HTTP2" && ok 'httpd is public in the two-port layout' || fail 'httpd is not public in the two-port layout'
check 'the two-port layout advertises the HTTP port' ":$HTTP2/t/" "$(extract_bootstrap_url)"

# ------------------------------------------------- the advertised address
# Behind NAT the one-liner must name the public address, not an interface
# one. An explicit value is passed straight through; left unset, the wrapper
# has to at least attempt the lookup and say what came of it (v0.5.0 shipped
# with the lookup never running, which this would have caught).
stop_server
PORT3="$(free_port)"
TEST_PUBLIC_IP='203.0.113.9' start_server "$PORT3" --no-http
wait_for_port "$PORT3" 30 || { fail 'the server did not start for the public address check'; summary; exit 1; }
check 'an explicit public address is advertised' 'tcp@203.0.113.9' "$(server_log)"
check 'the banner shows it as public, with the local addresses' '203.0.113.9 (public; local:' "$(server_log)"
stop_server
PORT4="$(free_port)"
TEST_PUBLIC_IP='' start_server "$PORT4" --no-http
wait_for_port "$PORT4" 30 || { fail 'the server did not start for the lookup check'; summary; exit 1; }
case "$(server_log)" in
	*'public IPv4 (ifconfig.me):'*) ok 'the wrapper looked the public address up' ;;
	*'public address lookup failed'*) ok 'the wrapper attempted the lookup (no answer here)' ;;
	*) fail 'the wrapper never attempted the public address lookup' ;;
esac

summary

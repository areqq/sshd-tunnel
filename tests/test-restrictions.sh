#!/bin/sh
# Negative assertions: everything the account must NOT be able to do.
# A tunnel that works is only half the requirement; the other half is that the
# same credentials buy nothing else.
#
# Order matters. The permitted forward is verified first, because OpenSSH 10
# applies PerSourcePenalties: a handful of failed authentications from one
# address earns that address a growing timeout, which would make a later
# legitimate connection fail for reasons unrelated to what is being tested.
set -eu

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_NAME='restrictions'
. tests/lib.sh

require python3 od sed timeout
require_dropbear_2014

PORT="$(free_port)"
RPORT="$(free_port)"
DEVPORT="$(free_port)"

cleanup() {
	[ -n "${TUNNEL_PID:-}" ] && kill "$TUNNEL_PID" 2>/dev/null
	[ -n "${LFWD_PID:-}" ] && kill "$LFWD_PID" 2>/dev/null
	stop_server
	stop_endpoint
	rm -rf "$TEST_TMP"
}
trap cleanup EXIT INT TERM HUP

printf '%s: sshd on %s, permitted reverse port %s\n' "$TEST_NAME" "$PORT" "$RPORT"

start_endpoint "$DEVPORT"
wait_for_port "$DEVPORT" 10 || { fail 'the stand-in device endpoint did not start'; summary; exit 1; }

# PermitListen is narrowed to a single port here, which covers the negative
# case for --listen as well.
start_server "$PORT" --no-http --listen "$RPORT"
if ! wait_for_port "$PORT" 30; then
	fail 'sshd did not start'
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi
extract_client_key "$TEST_TMP/id" || { fail 'no key printed'; summary; exit 1; }
dropbearconvert_2014 openssh dropbear "$TEST_TMP/id" "$TEST_TMP/id.db" >/dev/null 2>&1
export HOME="$TEST_TMP"

# ------------------------------------------------- the permitted case works first
"$DBCLIENT" -y -y -K 30 -I 0 -N -i "$TEST_TMP/id.db" \
	-R "$RPORT:127.0.0.1:$DEVPORT" -p "$PORT" tcp@127.0.0.1 >"$TEST_TMP/ok.log" 2>&1 &
TUNNEL_PID=$!
if wait_for_port "$RPORT" 30; then
	check 'the permitted reverse forward carries data' "$ECHO_TOKEN" "$(read_through_tunnel "$RPORT")"
else
	fail 'the permitted reverse forward did not come up'
	sed 's/^/          | /' "$TEST_TMP/ok.log"
fi

# ------------------------------------------------------------------- no shell
SHELL_OUT="$(timeout 15 "$DBCLIENT" -y -y -i "$TEST_TMP/id.db" -p "$PORT" tcp@127.0.0.1 \
	'id; echo SHELL_REACHED' 2>&1 || true)"
check 'a session channel gets the tunnel-only notice' 'only carries reverse TCP forwards' "$SHELL_OUT"
check_absent 'the requested command does not run' 'SHELL_REACHED' "$SHELL_OUT"
check_absent 'no uid output leaks from a shell' 'uid=' "$SHELL_OUT"

# ------------------------------------------------------- no local forwarding
LOCAL_PORT="$(free_port)"
timeout 20 "$DBCLIENT" -y -y -N -i "$TEST_TMP/id.db" \
	-L "$LOCAL_PORT:127.0.0.1:$DEVPORT" \
	-p "$PORT" tcp@127.0.0.1 >"$TEST_TMP/lfwd.log" 2>&1 &
LFWD_PID=$!
if wait_for_port "$LOCAL_PORT" 12; then
	# Dropbear opens the local listener regardless of policy; the refusal comes
	# when the channel is opened, so the black-box check is whether data flows.
	check_absent 'a -L forward carries no data' "$ECHO_TOKEN" "$(read_through_tunnel "$LOCAL_PORT")"
else
	ok 'the -L forward was not usable at all'
fi
kill "$LFWD_PID" 2>/dev/null || true
LFWD_PID=''

# --------------------------------------------------- PermitListen is enforced
OTHER_PORT="$(free_port)"
timeout 15 "$DBCLIENT" -y -y -N -i "$TEST_TMP/id.db" \
	-R "$OTHER_PORT:127.0.0.1:$DEVPORT" -p "$PORT" tcp@127.0.0.1 >"$TEST_TMP/denied.log" 2>&1 || true
if port_in_use "$OTHER_PORT"; then
	fail "a reverse forward outside PermitListen opened $OTHER_PORT anyway"
else
	ok 'a reverse forward outside PermitListen is refused'
fi
check 'the server logs the refusal' 'but the request was denied' "$(server_log)"

# ------------------------------------------------ only the tcp account is let in
# Asserted by outcome rather than by matching client messages: whatever wording
# Dropbear uses, a refused account must never end up with a listener.
for account in root admin nobody; do
	BAD_PORT="$(free_port)"
	timeout 12 "$DBCLIENT" -y -y -N -i "$TEST_TMP/id.db" \
		-R "$BAD_PORT:127.0.0.1:$DEVPORT" -p "$PORT" "$account@127.0.0.1" \
		>"$TEST_TMP/acct-$account.log" 2>&1 || true
	if port_in_use "$BAD_PORT"; then
		fail "account '$account' was allowed to open $BAD_PORT"
	else
		ok "account '$account' gets no forward"
	fi
done
if server_log | grep -qE 'Invalid user (root|admin|nobody)|not allowed because not listed'; then
	ok 'the server logs the rejected accounts'
else
	fail 'no rejection for the other accounts in the server log'
fi

# ---------------------------------------- passwords are rejected in key mode
PW_PORT="$(free_port)"
PW_OUT="$(DROPBEAR_PASSWORD='anything' timeout 15 "$DBCLIENT" -y -y -N \
	-R "$PW_PORT:127.0.0.1:$DEVPORT" -p "$PORT" tcp@127.0.0.1 2>&1 || true)"
if port_in_use "$PW_PORT"; then
	fail 'password authentication succeeded in key mode'
else
	ok 'password authentication gets no forward in key mode'
fi
check 'the client is offered no password method' 'No auth methods could be used' "$PW_OUT"

summary

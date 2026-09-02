# Shared helpers for the sshd-tunnel test suite. Sourced, not executed.
#
# Tests run against an unpacked release directory (the one holding `run` and
# `rootfs/`), on the host rather than in an unprivileged container: the chroot
# needs bind mounts, which require privileges a plain container does not have.
#
# Requires: root or passwordless sudo, python3 (for the endpoint used to prove
# that bytes actually traverse the tunnel), and a built Dropbear 2014 client.

: "${INSTALL_DIR:=dist/stage/sshd-tunnel}"
: "${DROPBEAR_DIR:=dist/dropbear-2014.63}"
: "${TEST_TMP:=$(mktemp -d)}"

ECHO_TOKEN='sshd-tunnel-tunnel-works'
FAILURES=0
CHECKS=0

SUDO=''
[ "$(id -u)" -eq 0 ] || SUDO='sudo'

ok() {
	CHECKS=$((CHECKS + 1))
	printf '  ok    %s\n' "$*"
}

fail() {
	CHECKS=$((CHECKS + 1))
	FAILURES=$((FAILURES + 1))
	printf '  FAIL  %s\n' "$*"
}

check() {
	# check <description> <expected-substring> <actual>
	case "$3" in
		*"$2"*) ok "$1" ;;
		*)      fail "$1 (expected to find '$2')"; printf '%s\n' "$3" | sed 's/^/          | /' ;;
	esac
}

check_absent() {
	case "$3" in
		*"$2"*) fail "$1 (unexpectedly found '$2')"; printf '%s\n' "$3" | sed 's/^/          | /' ;;
		*)      ok "$1" ;;
	esac
}

summary() {
	printf '\n%s: %s check(s), %s failure(s)\n' "${TEST_NAME:-test}" "$CHECKS" "$FAILURES"
	[ "$FAILURES" -eq 0 ]
}

require() {
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || {
			printf 'lib.sh: missing required tool: %s\n' "$tool" >&2
			exit 1
		}
	done
}

# ------------------------------------------------------------------- ports
port_in_use() {
	# /proc/net/tcp lists the local port in hex, state 0A is LISTEN.
	hexport="$(printf '%04X' "$1")"
	awk -v p=":$hexport" '$4 == "0A" && index($2, p) { found = 1 } END { exit !found }' \
		/proc/net/tcp /proc/net/tcp6 2>/dev/null
}

free_port() {
	while :; do
		candidate=$((20000 + $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % 20000))
		port_in_use "$candidate" || { printf '%s\n' "$candidate"; return 0; }
	done
}

wait_for_port() {
	# wait_for_port <port> [timeout-seconds]
	waited=0
	limit="${2:-20}"
	while [ "$waited" -lt "$limit" ]; do
		port_in_use "$1" && return 0
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

wait_for_text() {
	# wait_for_text <file> <substring> [timeout-seconds]
	waited=0
	limit="${3:-20}"
	while [ "$waited" -lt "$limit" ]; do
		grep -qF -- "$2" "$1" 2>/dev/null && return 0
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

# ------------------------------------------------------------------- server
start_server() {
	# start_server <args for ./run...>; sets SERVER_LOG and SERVER_PID
	SERVER_LOG="$TEST_TMP/server.log"
	: > "$SERVER_LOG"
	$SUDO "$INSTALL_DIR/run" "$@" >"$SERVER_LOG" 2>&1 &
	SERVER_PID=$!
}

mounts_under_rootfs() {
	rootfs="$(CDPATH='' cd -- "$INSTALL_DIR" && pwd)/rootfs"
	awk -v prefix="$rootfs/" 'index($2, prefix) == 1 { print $2 }' /proc/mounts | sort -r
}

stop_server() {
	[ -n "${SERVER_PID:-}" ] || return 0
	# SIGTERM reaches ./run, whose trap stops the chroot's sshd and bootstrap
	# server and then unmounts.
	$SUDO kill "$SERVER_PID" 2>/dev/null || true
	wait "$SERVER_PID" 2>/dev/null || true
	$SUDO pkill -f "$(CDPATH='' cd -- "$INSTALL_DIR" && pwd)/rootfs" 2>/dev/null || true
	SERVER_PID=''

	# Safety net. A leaked bind mount survives the process, makes the rootfs
	# impossible to delete, and silently breaks the next build; test-tunnel-key
	# asserts that the wrapper cleans up on its own, so reaching this loop is
	# already a bug being papered over.
	for leftover in $(mounts_under_rootfs); do
		$SUDO umount "$leftover" 2>/dev/null || $SUDO umount -l "$leftover" 2>/dev/null || true
	done
}

server_log() { cat "$SERVER_LOG" 2>/dev/null; }

extract_client_key() {
	# Writes the printed PEM key to $1. The BEGIN line names the algorithm
	# ("RSA PRIVATE KEY", "EC PRIVATE KEY"), so the marker is matched loosely.
	sed -n '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/p' \
		"$SERVER_LOG" > "$1"
	chmod 600 "$1"
	[ -s "$1" ]
}

extract_bootstrap_url() {
	grep -oE 'http://[0-9a-zA-Z.:]+/t/[0-9a-f]+/b' "$SERVER_LOG" | head -1
}

# --------------------------------------------------------------- endpoint
# A trivial TCP service standing in for whatever the device exposes. It answers
# every connection with a fixed token, so a successful read through the
# forwarded port is proof the tunnel carries data rather than merely existing.
start_endpoint() {
	python3 - "$1" "$ECHO_TOKEN" <<'PY' &
import socket, sys

port, token = int(sys.argv[1]), sys.argv[2].encode()
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', port))
srv.listen(8)
while True:
    conn, _ = srv.accept()
    try:
        conn.sendall(token + b'\n')
    except OSError:
        pass
    finally:
        conn.close()
PY
	ENDPOINT_PID=$!
}

stop_endpoint() {
	[ -n "${ENDPOINT_PID:-}" ] && kill "$ENDPOINT_PID" 2>/dev/null
	ENDPOINT_PID=''
}

read_through_tunnel() {
	python3 - "$1" <<'PY' 2>&1
import socket, sys

try:
    conn = socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=15)
    conn.settimeout(15)
    sys.stdout.write(conn.recv(256).decode(errors='replace').strip())
except OSError as exc:
    sys.stdout.write('connection failed: %s' % exc)
PY
}

# -------------------------------------------------------------- dropbear 2014
# The path, not just the wrapper function: `timeout` execs a program and
# cannot run a shell function.
DBCLIENT="$DROPBEAR_DIR/dbclient"

dbclient_2014() { "$DBCLIENT" "$@"; }
dropbearconvert_2014() { "$DROPBEAR_DIR/dropbearconvert" "$@"; }

require_dropbear_2014() {
	[ -x "$DROPBEAR_DIR/dbclient" ] || {
		printf 'lib.sh: no Dropbear 2014 client at %s — run tests/build-dropbear-2014.sh first\n' \
			"$DROPBEAR_DIR" >&2
		exit 1
	}
}

port_bound_wildcard() {
	# True when the listener is on 0.0.0.0 (or ::) rather than loopback, which
	# is what GatewayPorts yes is supposed to produce.
	hexport="$(printf '%04X' "$1")"
	awk -v want4="00000000:$hexport" \
		-v want6="00000000000000000000000000000000:$hexport" \
		'$4 == "0A" && ($2 == want4 || $2 == want6) { found = 1 } END { exit !found }' \
		/proc/net/tcp /proc/net/tcp6 2>/dev/null
}

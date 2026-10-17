#!/bin/sh
# The --serve mode, end to end: the server patches credentials into the client
# binaries and serves a one-liner; this host plays the device, runs that
# one-liner, and ends up with a Dropbear SSH server of its own exposed through
# the tunnel; then an OpenSSH client logs into it from the host side with the
# key the server printed. Everything the mode promises is asserted on the
# wire: identity, host key and authorized key all come out of the patched
# binary, not from any file on the "device".
set -eu

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_NAME='serve mode'
. tests/lib.sh

require python3 od sed timeout curl ssh ssh-keygen ssh-keyscan strings

PORT="$(free_port)"
RPORT="$(free_port)"
DEVPORT="$(free_port)"
DEVICE_DIR="$TEST_TMP/device"
LOGIN_USER="$(id -un)"

cleanup() {
	[ -n "${BOOTSTRAP_PID:-}" ] && kill "$BOOTSTRAP_PID" 2>/dev/null
	# The device-side server is a grandchild of the bootstrap script.
	pkill -f "$DEVICE_DIR/dropbearmulti" 2>/dev/null || true
	stop_server
	rm -rf "$TEST_TMP"
}
trap cleanup EXIT INT TERM HUP

# No --http: the default single-port layout, so the device fetches its binary
# and opens the tunnel through the same port, via sslh.
printf '%s: port %s (sshd + http via sslh), reverse %s, device %s\n' \
	"$TEST_NAME" "$PORT" "$RPORT" "$DEVPORT"

# A rootfs built without the client binaries has no --serve mode; that is a
# legitimate build, so the test is skipped rather than failed.
if [ ! -d "$INSTALL_DIR/rootfs/usr/local/share/sshd-tunnel/dropbear" ]; then
	printf '%s: the rootfs has no dropbear client binaries — skipping\n' "$TEST_NAME"
	exit 0
fi

# ------------------------------------------------------------ refused combos
OUT="$($SUDO "$INSTALL_DIR/run" "$PORT" 'secret' --serve 2>&1 || true)"
check '--serve with a password is refused' 'cannot be combined with a password' "$OUT"
OUT="$($SUDO "$INSTALL_DIR/run" "$PORT" --serve --no-http 2>&1 || true)"
check '--serve with --no-http is refused' 'needs the HTTP server' "$OUT"

# ------------------------------------------------------------------- start
start_server "$PORT" --serve --expose "$RPORT:127.0.0.1:$DEVPORT"
if ! wait_for_port "$PORT" 30; then
	fail 'the server did not start'
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi
wait_for_text "$SERVER_LOG" 'sslh listening' 20 || fail 'sslh did not start'

URL="$(grep -oE 'http://[0-9a-zA-Z.:]+/t/[0-9a-f]+/s' "$SERVER_LOG" | head -1)"
if [ -n "$URL" ]; then
	ok "the banner advertises $URL"
	check 'the one-liner uses the sshd port itself' ":$PORT/t/" "$URL"
else
	fail 'no --serve bootstrap URL in the startup output'
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi
BASE="${URL%/t/*}"
TOKEN_URL="${URL%/s}"

check 'the banner lists the served architectures' 'binaries served  : ' "$(server_log)"
for arch in x86_64 i686 armv7 armv5 aarch64 mips mipsel; do
	check "  $arch is served" " $arch " "$(server_log | grep 'binaries served')"
done

DEVICE_FP="$(server_log | sed -n 's/.*Its host key SHA256: //p' | head -1)"
if [ -n "$DEVICE_FP" ]; then
	ok "the banner names the device host key ($DEVICE_FP)"
else
	fail 'no device host key fingerprint in the banner'
fi

# The operator key is printed in the banner, like the client key in the
# plain key mode. The BEGIN marker is OpenSSH's, not PEM's.
sed -n '/-----BEGIN OPENSSH PRIVATE KEY-----/,/-----END OPENSSH PRIVATE KEY-----/p' \
	"$SERVER_LOG" > "$TEST_TMP/device_key"
chmod 600 "$TEST_TMP/device_key"
if [ -s "$TEST_TMP/device_key" ] && ssh-keygen -y -f "$TEST_TMP/device_key" >"$TEST_TMP/device_key.pub" 2>/dev/null; then
	ok 'the banner carries a usable operator key'
else
	fail 'no usable operator key in the banner'
	summary
	exit 1
fi
check 'the banner shows where the key lives on the host' "$INSTALL_DIR/rootfs/run/sshd-tunnel/device_key" "$(server_log)" \
	|| true
HOST_KEY_PATH="$(CDPATH='' cd -- "$INSTALL_DIR" && pwd)/rootfs/run/sshd-tunnel/device_key"
if $SUDO test -f "$HOST_KEY_PATH"; then
	ok 'the operator key exists at the advertised host path'
else
	fail "no operator key at $HOST_KEY_PATH"
fi

# ------------------------------------------------------------- token required
for path in '/' '/t/' '/t/0000000000000000000000000000000/s' '/t/0000000000000000000000000000000/bin/dropbearmulti-x86_64'; do
	CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE$path" || echo 000)"
	case "$CODE" in
		200) fail "$path returned 200 without a valid token" ;;
		*)   ok "$path is not served (HTTP $CODE)" ;;
	esac
done

# ------------------------------------------------------ the served binaries
curl -fsS -o "$TEST_TMP/s" "$URL" || { fail 'cannot fetch the bootstrap script'; summary; exit 1; }
ok 'the bootstrap script downloads'
sh -n "$TEST_TMP/s" && ok 'the bootstrap script is valid POSIX shell' || fail 'the bootstrap script does not parse'
check 'it targets the tcp account' 'tcp@' "$(cat "$TEST_TMP/s")"
check 'it carries the reverse mapping' "RPORT='$RPORT'" "$(cat "$TEST_TMP/s")"
check_absent 'it carries no private key: that is inside the binary' 'PRIVATE KEY' "$(cat "$TEST_TMP/s")"

curl -fsS -o "$TEST_TMP/dbm-x86_64" "$TOKEN_URL/bin/dropbearmulti-x86_64" \
	|| { fail 'cannot fetch the x86_64 binary'; summary; exit 1; }
AK_B64="$(base64 -w0 < "$TEST_TMP/device_key.pub" 2>/dev/null || base64 < "$TEST_TMP/device_key.pub" | tr -d '\n')"
# ssh-keygen -y prints the key without the comment; the served line has the
# comment appended, so compare on the key material only.
AK_PREFIX="$(printf '%s' "$AK_B64" | cut -c1-60)"
if strings -- "$TEST_TMP/dbm-x86_64" | grep -q "@@DBCRED:ak:B@@$AK_PREFIX"; then
	ok 'the served binary carries the operator public key in its ak slot'
else
	fail 'the ak slot of the served binary does not hold the operator key'
fi
for slot in id hk; do
	if strings -- "$TEST_TMP/dbm-x86_64" | grep -q "@@DBCRED:$slot:B@@\.\."; then
		fail "the $slot slot of the served binary is empty"
	else
		ok "the $slot slot of the served binary is populated"
	fi
done
PRISTINE="$INSTALL_DIR/rootfs/usr/local/share/sshd-tunnel/dropbear/dropbearmulti-x86_64"
if $SUDO strings -- "$PRISTINE" | grep -q '@@DBCRED:id:B@@\.\.'; then
	ok 'the pristine binary in the rootfs was not patched'
else
	fail 'the pristine binary in the rootfs has been modified'
fi

# ---------------------------------------------------------------- run it
# This host is the device. Nothing from PATH is used by the script except
# the downloader; the SSH server and client are the fetched binary.
mkdir -p "$DEVICE_DIR"
DIR="$DEVICE_DIR" HOME="$TEST_TMP" sh "$TEST_TMP/s" >"$TEST_TMP/bootstrap.log" 2>&1 &
BOOTSTRAP_PID=$!

if wait_for_port "$RPORT" 40; then
	ok "the one-liner brought up the reverse listener on $RPORT"
else
	fail 'the one-liner did not establish the tunnel'
	sed 's/^/          | /' "$TEST_TMP/bootstrap.log"
	[ -f "$DEVICE_DIR/server.log" ] && sed 's/^/   device | /' "$DEVICE_DIR/server.log"
	server_log | sed 's/^/          | /'
	summary
	exit 1
fi
check 'the script verified the binary runs here' 'binary verified' "$(cat "$TEST_TMP/bootstrap.log")"
check 'the script started the device SSH server' 'starting the SSH server' "$(cat "$TEST_TMP/bootstrap.log")"

# ------------------------------------------------- the device's host key
SCANNED="$(ssh-keyscan -t ed25519 -p "$RPORT" 127.0.0.1 2>/dev/null | head -1)"
SCANNED_FP="$(printf '%s\n' "$SCANNED" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
if [ -n "$SCANNED_FP" ] && [ "$SCANNED_FP" = "$DEVICE_FP" ]; then
	ok 'the device presents the host key the banner announced'
else
	fail "device host key mismatch: banner $DEVICE_FP, on the wire ${SCANNED_FP:-none}"
fi
check 'the device server used the embedded host key' 'Using embedded ed25519 hostkey' "$(cat "$DEVICE_DIR/server.log")"

# ------------------------------------------------------------ log in
printf '[127.0.0.1]:%s %s\n' "$RPORT" "$(printf '%s\n' "$SCANNED" | cut -d' ' -f2-)" > "$TEST_TMP/known_hosts"
OUT="$(timeout 30 ssh -i "$TEST_TMP/device_key" -p "$RPORT" \
	-o IdentitiesOnly=yes -o UserKnownHostsFile="$TEST_TMP/known_hosts" -o StrictHostKeyChecking=yes \
	-o BatchMode=yes "$LOGIN_USER@127.0.0.1" "echo serve-login-ok-\$(id -un)" 2>&1 || true)"
check 'ssh logs into the device through the tunnel with the printed key' "serve-login-ok-$LOGIN_USER" "$OUT"

# A key the device was never told about must be refused: the ak slot is the
# whole authorized_keys, and password auth is compiled out.
ssh-keygen -q -t ed25519 -N '' -f "$TEST_TMP/stranger" 2>/dev/null
OUT="$(timeout 30 ssh -i "$TEST_TMP/stranger" -p "$RPORT" \
	-o IdentitiesOnly=yes -o UserKnownHostsFile="$TEST_TMP/known_hosts" -o StrictHostKeyChecking=yes \
	-o BatchMode=yes "$LOGIN_USER@127.0.0.1" 'echo stranger-got-in' 2>&1 || true)"
check_absent 'a key the device does not know is refused' 'stranger-got-in' "$OUT"

# ------------------------------------------------------------- cleanup
stop_server
if $SUDO test -e "$HOST_KEY_PATH"; then
	fail 'the operator key survived the server stopping'
else
	ok 'the operator key is removed when the server stops'
fi

summary

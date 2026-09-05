#!/bin/sh
# Verify a built DSVPN package.
#
#   vpn-client/verify.sh <arch> <tarball>
#
# Three separate things, in increasing order of strength:
#
#   1. the binary is static and built for the architecture it claims,
#   2. it executes on that architecture (natively, or under qemu-<arch>-static),
#   3. the no-system-changes patch is actually in the binary — checked against
#      the strings that would only be there if it were not,
#   4. for a natively runnable build, a real tunnel between two network
#      namespaces carries traffic both ways.
#
# (4) is the one that matters for this project: the patch cuts dsvpn's setup
# down to `ip link set up` plus `ip addr add ... peer ...`, and the question it
# answers is whether that is still enough to bring a working tunnel up. Two
# namespaces joined by a veth pair give real tun devices and real crypto
# without touching the runner's own networking.
#
# Needs root for (4) only; without it that step is skipped, not failed.

set -Eeu

ARCH="${1:?usage: verify.sh <arch> <tarball>}"
TARBALL="${2:?usage: verify.sh <arch> <tarball>}"

HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
WORK="$HERE/.verify/$ARCH"

NS_A='dsvpnverify-a'
NS_B='dsvpnverify-b'
PORT='34567'

log()  { printf '==> %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
die()  { printf 'verify.sh: %s\n' "$*" >&2; exit 1; }

[ -f "$TARBALL" ] || die "no such tarball: $TARBALL"

SERVER_PID=''
CLIENT_PID=''
cleanup() {
	set +e
	[ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	if [ "$(id -u)" -eq 0 ]; then
		ip netns del "$NS_A" 2>/dev/null
		ip netns del "$NS_B" 2>/dev/null
	fi
	return 0
}
trap cleanup EXIT INT TERM

rm -rf "$WORK"
mkdir -p "$WORK"
tar xzf "$TARBALL" -C "$WORK" --strip-components=1
BIN="$WORK/dsvpn"
[ -x "$BIN" ] || die 'the tarball contains no executable dsvpn'

# ------------------------------------------------------------------ 1. shape
log "checking the ELF of $ARCH"
case "$ARCH" in
	x86_64)  WANT='x86-64' ;;
	i686)    WANT='Intel 80386' ;;
	armv7)   WANT='ARM' ;;
	armv5)   WANT='ARM' ;;
	aarch64) WANT='aarch64' ;;
	mips)    WANT='MIPS' ;;
	mipsel)  WANT='MIPS' ;;
	*) die "unknown arch: $ARCH" ;;
esac
FILE_OUT="$(file -L "$BIN")"
case "$FILE_OUT" in
	*"$WANT"*) ok "ELF machine matches $ARCH" ;;
	*) die "expected $WANT in: $FILE_OUT" ;;
esac
case "$FILE_OUT" in
	*'statically linked'*) ok 'statically linked' ;;
	*) die "not static: $FILE_OUT" ;;
esac
# MIPS endianness is the one thing `file` distinguishes but the arch name does
# not, and getting it wrong produces a binary that fails only on the device.
case "$ARCH:$FILE_OUT" in
	mips:*MSB*|mipsel:*LSB*) ok 'byte order matches' ;;
	mips:*|mipsel:*) die "wrong byte order for $ARCH: $FILE_OUT" ;;
esac

# ----------------------------------------------------------- 2. does it run
log 'checking it executes'
RUNNER=''
if [ "$ARCH" = 'x86_64' ] && [ "$(uname -m)" = 'x86_64' ]; then
	RUNNER=''
elif command -v "qemu-$ARCH-static" >/dev/null 2>&1; then
	RUNNER="qemu-$ARCH-static"
elif [ "$ARCH" = 'armv7' ] || [ "$ARCH" = 'armv5' ]; then
	command -v qemu-arm-static >/dev/null 2>&1 && RUNNER='qemu-arm-static'
elif [ "$ARCH" = 'i686' ]; then
	command -v qemu-i386-static >/dev/null 2>&1 && RUNNER='qemu-i386-static'
fi

# With no arguments dsvpn prints its usage and exits 254, which is enough to
# prove the CPU accepts every instruction the compiler emitted for startup.
# A float-ABI mismatch shows up here as SIGILL — that is a real bug this
# project has shipped once before, on MIPS, in the SFTP client.
if [ -n "$RUNNER" ]; then
	OUT="$($RUNNER "$BIN" 2>&1 || true)"
	VIA=" (via $RUNNER)"
elif [ -z "$RUNNER" ] && [ "$ARCH" = 'x86_64' ]; then
	OUT="$("$BIN" 2>&1 || true)"
	VIA=''
else
	OUT=''
	VIA=''
	printf '  skip  no emulator for %s; cannot check that it runs\n' "$ARCH"
fi
if [ -n "$VIA" ] || [ "$ARCH" = 'x86_64' ]; then
	case "$OUT" in
		*DSVPN*) ok "runs and prints its usage$VIA" ;;
		*) die "the binary did not run$VIA: $OUT" ;;
	esac
fi

# ---------------------------------------------- 3. the patch is in the binary
# The command strings live in .rodata, so their absence is direct evidence
# that patches/no-system-changes.patch applied. Without this, a patch that
# silently stopped matching upstream would ship a client that rewrites the
# device's routing table — the exact failure this project must not have.
log 'checking the no-system-changes patch took effect'
for forbidden in iptables 42069 ip_forward tcp_congestion_control suppress_prefixlength; do
	if strings -a "$BIN" | grep -q -- "$forbidden"; then
		die "the binary still contains '$forbidden' — the patch did not apply"
	fi
	ok "no '$forbidden' in the binary"
done
# And the two that must remain, or the tunnel would never come up.
for required in 'ip link set dev $IF_NAME up' 'ip addr add $LOCAL_TUN_IP peer $REMOTE_TUN_IP dev $IF_NAME'; do
	strings -a "$BIN" | grep -qF -- "$required" \
		|| die "the binary is missing the command: $required"
	ok "kept: $required"
done

# --------------------------------------------------------- 4. a real tunnel
if [ "$ARCH" != 'x86_64' ] || [ "$(uname -m)" != 'x86_64' ]; then
	printf '  skip  the tunnel test runs only for a natively executable build\n'
	log 'done'
	exit 0
fi
if [ "$(id -u)" -ne 0 ]; then
	printf '  skip  the tunnel test needs root (network namespaces)\n'
	log 'done'
	exit 0
fi
if [ ! -c /dev/net/tun ]; then
	printf '  skip  no /dev/net/tun on this machine\n'
	log 'done'
	exit 0
fi

log 'bringing up a real tunnel between two network namespaces'
ip netns del "$NS_A" 2>/dev/null || true
ip netns del "$NS_B" 2>/dev/null || true
ip netns add "$NS_A"
ip netns add "$NS_B"
ip link add dsvv-a type veth peer name dsvv-b
ip link set dsvv-a netns "$NS_A"
ip link set dsvv-b netns "$NS_B"
ip netns exec "$NS_A" ip addr add 192.0.2.1/24 dev dsvv-a
ip netns exec "$NS_B" ip addr add 192.0.2.2/24 dev dsvv-b
ip netns exec "$NS_A" ip link set dsvv-a up
ip netns exec "$NS_B" ip link set dsvv-b up
ip netns exec "$NS_A" ip link set lo up
ip netns exec "$NS_B" ip link set lo up
ip netns exec "$NS_B" ping -c 1 -W 3 192.0.2.1 >/dev/null 2>&1 \
	|| die 'the veth pair itself does not carry traffic'
ok 'veth pair up'

dd if=/dev/urandom of="$WORK/key" bs=32 count=1 >/dev/null 2>&1

ip netns exec "$NS_A" "$BIN" server "$WORK/key" auto "$PORT" auto 10.77.0.1 10.77.0.2 auto \
	>"$WORK/server.log" 2>&1 &
SERVER_PID=$!
sleep 2
kill -0 "$SERVER_PID" 2>/dev/null || { cat "$WORK/server.log"; die 'the server exited immediately'; }
ok 'server up'

ip netns exec "$NS_B" "$BIN" client "$WORK/key" 192.0.2.1 "$PORT" auto 10.77.0.2 10.77.0.1 auto \
	>"$WORK/client.log" 2>&1 &
CLIENT_PID=$!
sleep 3
kill -0 "$CLIENT_PID" 2>/dev/null || { cat "$WORK/client.log"; die 'the client exited immediately'; }
ok 'client up'

ip netns exec "$NS_B" ping -c 3 -W 5 10.77.0.1 >"$WORK/ping-b.log" 2>&1 \
	|| { cat "$WORK/client.log" "$WORK/ping-b.log"; die 'client -> server does not pass through the tunnel'; }
ok 'client -> server ping'

ip netns exec "$NS_A" ping -c 3 -W 5 10.77.0.2 >"$WORK/ping-a.log" 2>&1 \
	|| { cat "$WORK/server.log" "$WORK/ping-a.log"; die 'server -> client does not pass through the tunnel'; }
ok 'server -> client ping'

# Payloads larger than the outer path MTU: dsvpn tunnels over TCP, so these
# have to be carried by the outer stream rather than fragmented away.
ip netns exec "$NS_B" ping -c 2 -W 5 -s 2000 10.77.0.1 >"$WORK/ping-big.log" 2>&1 \
	|| { cat "$WORK/ping-big.log"; die '2000-byte payloads do not survive the tunnel'; }
ok '2000-byte payloads'

# The point of the patch, asserted rather than assumed: neither namespace ends
# up with a policy routing rule or a rewritten default route.
for ns in "$NS_A" "$NS_B"; do
	RULES="$(ip netns exec "$ns" ip rule show | grep -c . || true)"
	[ "$RULES" -eq 3 ] || {
		ip netns exec "$ns" ip rule show
		die "$ns has $RULES ip rules, expected the 3 stock ones — something installed policy routing"
	}
	ip netns exec "$ns" ip route show | grep -q '^default' \
		&& { ip netns exec "$ns" ip route show; die "$ns gained a default route"; }
	ok "$ns: routing untouched"
done

log 'done'

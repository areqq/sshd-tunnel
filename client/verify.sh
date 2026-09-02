#!/bin/bash
# CI/dev-host helper only (not shipped to devices, so bash + /dev/tcp are fine
# here — unlike bootstrap.sh, which must stay POSIX ash).
#
# End-to-end verification of one built dropbear-tunnel tarball: proves the
# credential-slot mechanism actually works, not just that the binary links.
#
#   client/verify.sh <arch> <tarball.tgz>
#
# For the given arch's binary (run under qemu-<arch>-static so this also
# covers non-native CI runners):
#   1. patches id/hk/ak with patch-cred, asserts file size is unchanged and
#      the ELF is still valid, then proves a live login: the embedded server
#      presents the patched hk, accepts the patched ak, and dbclient
#      authenticates with the patched id (no -i given — load_embedded_identity
#      is what's under test)
#   2. re-patches id+ak with raw sed (the mechanism README documents as an
#      alternative to patch-cred) and repeats the live login with a *different*
#      keypair, proving both patch paths work, not just patch-cred's
#
# Needs: qemu-<arch>-static on PATH (Ubuntu's qemu-user-static package),
# unless arch is the host's native arch.
set -eu

ARCH="${1:?usage: verify.sh <arch> <tarball.tgz>}"
TARBALL="${2:?usage: verify.sh <arch> <tarball.tgz>}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'verify: %s\n' "$*" >&2; exit 1; }
trap 'printf "verify: TRAP set -e at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

case "$ARCH" in
	x86_64)  QEMU=qemu-x86_64-static ;;
	i686)    QEMU=qemu-i386-static ;;
	armv7)   QEMU=qemu-arm-static ;;
	armv5)   QEMU=qemu-arm-static ;;
	aarch64) QEMU=qemu-aarch64-static ;;
	mips)    QEMU=qemu-mips-static ;;
	mipsel)  QEMU=qemu-mipsel-static ;;
	*) die "unknown arch: $ARCH" ;;
esac
command -v "$QEMU" >/dev/null 2>&1 || die "$QEMU not found on PATH"
RUN="$QEMU"

WORK="$(mktemp -d)"
SPID=""
trap '[ -n "$SPID" ] && kill "$SPID" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

tar xzf "$TARBALL" -C "$WORK"
DIR="$(find "$WORK" -maxdepth 1 -type d -name 'dropbear-tunnel-*')"
BIN="$DIR/dropbearmulti"
[ -x "$BIN" ] || die "dropbearmulti missing in $TARBALL"

for m in id hk ak; do
	strings "$BIN" | grep -q "@@DBCRED:$m:B@@" || die "slot marker $m missing before patching"
done

PORT=2299
HOME="$WORK" # dropbearkey/dbclient write under $HOME/.ssh; keep it scoped to this run
export HOME
mkdir -p "$HOME/.ssh"

wait_for_port() {
	i=0
	while ! (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -lt 50 ] || die "server never opened port $PORT"
		sleep 0.2
	done
	exec 3>&- 3<&- 2>/dev/null || true
}

start_server() {
	$RUN "$BIN" dropbear -F -E -p "127.0.0.1:$PORT" >"$WORK/server.log" 2>&1 &
	SPID=$!
	wait_for_port
}

stop_server() {
	kill "$SPID" 2>/dev/null || true
	wait "$SPID" 2>/dev/null || true
	SPID=""
}

login_and_check() {
	label="$1"
	out="$($RUN "$BIN" dbclient -y -p "$PORT" q@127.0.0.1 "echo VERIFY_${label}_OK" 2>&1)" \
		|| { printf '%s\n' "$out" >&2; die "$label: dbclient login failed"; }
	printf '%s\n' "$out" | grep -q "VERIFY_${label}_OK" || { printf '%s\n' "$out" >&2; die "$label: expected marker not in dbclient output"; }
	grep -q 'Using embedded ed25519 hostkey' "$WORK/server.log" || die "$label: server did not report using the embedded hostkey"
	log "$label: dbclient authenticated with the embedded identity and the embedded hostkey/authorized_key were used"
}

# ---------------------------------------------------------- patch-cred path
log 'generating slot 1 keys (identity, hostkey)'
$RUN "$BIN" dropbearkey -t ed25519 -f "$WORK/id1" >/dev/null 2>&1
$RUN "$BIN" dropbearkey -t ed25519 -f "$WORK/hostkey" >/dev/null 2>&1
$RUN "$BIN" dropbearkey -y -f "$WORK/id1" 2>/dev/null | grep '^ssh-ed25519' >"$WORK/ak1.txt"

before="$(wc -c <"$BIN")"
"$DIR/patch-cred" "$BIN" id "$WORK/id1"
"$DIR/patch-cred" "$BIN" hk "$WORK/hostkey"
"$DIR/patch-cred" "$BIN" ak "$WORK/ak1.txt"
after="$(wc -c <"$BIN")"
[ "$before" = "$after" ] || die "patch-cred: size changed $before -> $after"
file "$BIN" | grep -q 'ELF' || die "patch-cred: no longer a valid ELF"

start_server
login_and_check PATCHCRED
stop_server

# -------------------------------------------------------------- raw sed path
# README documents this as the manual alternative to patch-cred: replace the
# marker-delimited region with a same-width, '.'-padded base64 blob via sed.
log 'generating slot 2 keys (a different identity) for the raw-sed path'
$RUN "$BIN" dropbearkey -t ed25519 -f "$WORK/id2" >/dev/null 2>&1
$RUN "$BIN" dropbearkey -y -f "$WORK/id2" 2>/dev/null | grep '^ssh-ed25519' >"$WORK/ak2.txt"

sed_patch_slot() {
	slot="$1"; payload="$2"
	boff="$(grep -abo -- "@@DBCRED:$slot:B@@" "$BIN" | head -1 | cut -d: -f1)"
	eoff="$(grep -abo -- "@@DBCRED:$slot:E@@" "$BIN" | head -1 | cut -d: -f1)"
	width=$((eoff - boff - 15))
	b64="$(base64 -w0 <"$payload")"
	pad=$((width - ${#b64}))
	padding="$(awk -v n="$pad" 'BEGIN{s="";for(i=0;i<n;i++)s=s".";printf "%s",s}')"
	LC_ALL=C sed -i "s|@@DBCRED:$slot:B@@[^@]*@@DBCRED:$slot:E@@|@@DBCRED:$slot:B@@${b64}${padding}@@DBCRED:$slot:E@@|" "$BIN"
}

before="$(wc -c <"$BIN")"
sed_patch_slot id "$WORK/id2"
sed_patch_slot ak "$WORK/ak2.txt"
after="$(wc -c <"$BIN")"
[ "$before" = "$after" ] || die "raw sed: size changed $before -> $after"
file "$BIN" | grep -q 'ELF' || die "raw sed: no longer a valid ELF"

start_server
login_and_check RAWSED
stop_server

log "$ARCH: all credential-slot checks passed (patch-cred + raw sed, live login both times)"

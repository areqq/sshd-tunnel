#!/bin/bash
# CI/dev-host helper only (not shipped to devices).
#
# End-to-end verification of one WITH_SFTP=1 dropbear-tunnel tarball: proves a
# real file transfer both ways, under qemu-<arch>-static, not just that the
# sftp/sftp-server binaries link and run.
#
#   client/verify-sftp.sh <arch> <sftp-tarball.tgz>
#
# Server side: the embedded dropbear server execs /tmp/sftp-server (staged the
# way bootstrap.sh --serve does) for the SFTP subsystem.
# Client side: the bundled OpenSSH `sftp` routes its session through the
# packaged `dbclient` symlink (`sftp -S ./dbclient`, per the README) — the
# multi-call binary only dispatches correctly when invoked under that name.
set -eu

ARCH="${1:?usage: verify-sftp.sh <arch> <tarball.tgz>}"
TARBALL="${2:?usage: verify-sftp.sh <arch> <tarball.tgz>}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'verify-sftp: %s\n' "$*" >&2; exit 1; }

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
trap '[ -n "$SPID" ] && kill "$SPID" 2>/dev/null; rm -rf "$WORK" /tmp/sftp-server-verify-$$' EXIT INT TERM

tar xzf "$TARBALL" -C "$WORK"
DIR="$(find "$WORK" -maxdepth 1 -type d -name 'dropbear-tunnel-*')"
BIN="$DIR/dropbearmulti"
[ -x "$BIN" ] || die "dropbearmulti missing in $TARBALL"
[ -x "$DIR/sftp" ] || die "sftp client missing in $TARBALL"
[ -x "$DIR/sftp-server" ] || die "sftp-server missing in $TARBALL"
[ -L "$DIR/dbclient" ] || die "dbclient symlink missing in $TARBALL (needed for sftp -S)"

PORT=2298
SFTPSERVER_STAGE="/tmp/sftp-server-verify-$$"
cp "$DIR/sftp-server" "$SFTPSERVER_STAGE"
chmod 755 "$SFTPSERVER_STAGE"
[ "$SFTPSERVER_STAGE" = "/tmp/sftp-server" ] || ln -sf "$SFTPSERVER_STAGE" /tmp/sftp-server

HOME="$WORK"
export HOME
mkdir -p "$HOME/.ssh"

log 'generating identity, hostkey, authorized_keys'
$RUN "$BIN" dropbearkey -t ed25519 -f "$WORK/id_new" >/dev/null 2>&1
$RUN "$BIN" dropbearkey -t ed25519 -f "$WORK/hostkey" >/dev/null 2>&1
$RUN "$BIN" dropbearkey -y -f "$WORK/id_new" 2>/dev/null | grep '^ssh-ed25519' >"$WORK/ak.txt"
"$DIR/patch-cred" "$BIN" id "$WORK/id_new"
"$DIR/patch-cred" "$BIN" hk "$WORK/hostkey"
"$DIR/patch-cred" "$BIN" ak "$WORK/ak.txt"

wait_for_port() {
	i=0
	while ! (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -lt 50 ] || die "server never opened port $PORT"
		sleep 0.2
	done
	exec 3>&- 3<&- 2>/dev/null || true
}

$RUN "$BIN" dropbear -F -E -p "127.0.0.1:$PORT" >"$WORK/server.log" 2>&1 &
SPID=$!
wait_for_port

echo "sftp-e2e-payload-$$" >"$WORK/upload.txt"

log 'uploading a file over sftp (client transport: dbclient, server subsystem: sftp-server)'
out="$($RUN "$DIR/sftp" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-S "$DIR/dbclient" -P "$PORT" q@127.0.0.1 <<EOF
put $WORK/upload.txt $WORK/downloaded.txt
EOF
)" || { printf '%s\n' "$out" >&2; die 'sftp put failed'; }

[ -f "$WORK/downloaded.txt" ] || { printf '%s\n' "$out" >&2; die 'sftp put did not produce the file'; }
diff -q "$WORK/upload.txt" "$WORK/downloaded.txt" >/dev/null || die 'uploaded file content mismatch'

kill "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true
SPID=""

log "$ARCH: SFTP round-trip verified (uploaded file content matches)"

#!/bin/sh
# Download a released sshd-tunel chroot and start it.
#
#   curl -fsSL https://raw.githubusercontent.com/areqq/sshd-tunel/main/install.sh | sh -s -- <port> [password]
#
# With no arguments it only installs and prints how to start the server.
# The chroot is unpacked into ./sshd-tunel; an existing installation keeps its
# SSH host key so clients do not see a changed fingerprint after an upgrade.
#
# Environment:
#   SSHD_TUNEL_REPO     owner/name          (default: areqq/sshd-tunel)
#   SSHD_TUNEL_VERSION  release tag or latest (default: latest)
#   SSHD_TUNEL_ARCH     architecture        (default: x86_64)
#   SSHD_TUNEL_DIR      install directory   (default: ./sshd-tunel)

set -eu

PROG='sshd-tunel-install'
REPO="${SSHD_TUNEL_REPO:-areqq/sshd-tunel}"
VERSION="${SSHD_TUNEL_VERSION:-latest}"
ARCH="${SSHD_TUNEL_ARCH:-x86_64}"
DEST="${SSHD_TUNEL_DIR:-./sshd-tunel}"

TARBALL="sshd-tunel-$ARCH.tgz"
if [ "$VERSION" = 'latest' ]; then
	BASE_URL="https://github.com/$REPO/releases/latest/download"
else
	BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
fi

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

# -------------------------------------------------------------------- tooling
if command -v curl >/dev/null 2>&1; then
	fetch() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
	fetch() { wget -q -O "$2" "$1"; }
else
	die 'need curl or wget'
fi

if command -v sha256sum >/dev/null 2>&1; then
	checksum() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
	checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
	die 'need sha256sum or shasum to verify the download'
fi

for tool in tar mktemp; do
	command -v "$tool" >/dev/null 2>&1 || die "need $tool"
done

# ------------------------------------------------------------------- download
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM HUP

log "downloading $TARBALL ($VERSION)"
fetch "$BASE_URL/$TARBALL" "$WORKDIR/$TARBALL" \
	|| die "cannot download $BASE_URL/$TARBALL"
fetch "$BASE_URL/$TARBALL.sha256" "$WORKDIR/$TARBALL.sha256" \
	|| die "cannot download the checksum for $TARBALL"

EXPECTED="$(cut -d' ' -f1 < "$WORKDIR/$TARBALL.sha256")"
ACTUAL="$(checksum "$WORKDIR/$TARBALL")"
[ -n "$EXPECTED" ] || die 'the published checksum file is empty'
[ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch: expected $EXPECTED, got $ACTUAL"
log 'checksum verified'

# -------------------------------------------------------------------- unpack
mkdir -p "$WORKDIR/unpacked"
tar xzf "$WORKDIR/$TARBALL" -C "$WORKDIR/unpacked"
[ -d "$WORKDIR/unpacked/sshd-tunel" ] || die 'unexpected tarball layout'

OLD_HOST_KEY="$DEST/rootfs/etc/ssh/ssh_host_rsa_key"
if [ -f "$OLD_HOST_KEY" ]; then
	# Carrying the host key across upgrades keeps Dropbear clients that store
	# host keys from treating the new install as a different server.
	log 'preserving the existing SSH host key'
	cp "$OLD_HOST_KEY" "$WORKDIR/unpacked/sshd-tunel/rootfs/etc/ssh/ssh_host_rsa_key"
	[ -f "$OLD_HOST_KEY.pub" ] && \
		cp "$OLD_HOST_KEY.pub" "$WORKDIR/unpacked/sshd-tunel/rootfs/etc/ssh/ssh_host_rsa_key.pub"
fi

if [ -e "$DEST" ]; then
	log "replacing the existing installation in $DEST"
	rm -rf "$DEST"
fi
mkdir -p "$(dirname -- "$DEST")"
mv "$WORKDIR/unpacked/sshd-tunel" "$DEST"
log "installed into $DEST"

# --------------------------------------------------------------------- start
if [ $# -eq 0 ]; then
	cat <<EOF

Installed. Start the server with:

  sudo $DEST/run <port>              key-only auth, key printed at startup
  sudo $DEST/run <port> <password>   password-only auth

See $DEST/README.md for the options.
EOF
	exit 0
fi

log "starting: $DEST/run $*"
exec "$DEST/run" "$@"

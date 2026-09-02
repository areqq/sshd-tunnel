#!/bin/sh
# Run the whole suite against an unpacked release directory.
#
#   tests/run-all.sh [install-dir]
#
# Defaults to dist/stage/sshd-tunnel, which is what build/build.sh leaves
# behind. Needs root or passwordless sudo, python3, and a toolchain for the
# Dropbear 2014 client (built once into dist/).

set -eu

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

export DROPBEAR_DIR="${DROPBEAR_DIR:-dist/dropbear-2014.63}"

SUDO=''
[ "$(id -u)" -eq 0 ] || SUDO='sudo'

if [ -n "${1:-}" ]; then
	INSTALL_DIR="$1"
else
	# Test the actual release artefact rather than the build staging directory.
	# Two reasons: it is what users get, and the chroot's entrypoint chowns its
	# own root to root:root, which would leave the staging directory unwritable
	# for the next build.
	TARBALL="dist/sshd-tunnel-x86_64.tgz"
	[ -f "$TARBALL" ] || {
		printf 'run-all: %s not found — run build/build.sh first\n' "$TARBALL" >&2
		exit 1
	}
	UNPACK_DIR="$(mktemp -d)"
	printf '=== unpacking %s into %s ===\n' "$TARBALL" "$UNPACK_DIR"
	# Unpacked as root so the archive's ownership survives: sshd enforces
	# StrictModes on /var/empty and on the path to authorized_keys.
	$SUDO tar xzf "$TARBALL" -C "$UNPACK_DIR"
	INSTALL_DIR="$UNPACK_DIR/sshd-tunnel"
	cleanup_unpack() {
		for leftover in $(awk -v p="$INSTALL_DIR/rootfs/" 'index($2, p) == 1 { print $2 }' \
			/proc/mounts | sort -r); do
			$SUDO umount -l "$leftover" 2>/dev/null || true
		done
		$SUDO rm -rf "$UNPACK_DIR"
	}
	trap cleanup_unpack EXIT INT TERM HUP
fi
export INSTALL_DIR

[ -x "$INSTALL_DIR/run" ] || {
	printf 'run-all: no release directory at %s\n' "$INSTALL_DIR" >&2
	exit 1
}

printf '=== building the Dropbear 2014 client ===\n'
tests/build-dropbear-2014.sh "$DROPBEAR_DIR"

FAILED=''
for test in \
	tests/test-tunnel-key.sh \
	tests/test-key-types.sh \
	tests/test-tunnel-password.sh \
	tests/test-restrictions.sh \
	tests/test-bootstrap.sh
do
	printf '\n=== %s ===\n' "$test"
	if "$test"; then
		printf '%s: PASS\n' "$test"
	else
		printf '%s: FAIL\n' "$test"
		FAILED="$FAILED $test"
	fi
done

printf '\n===============================================\n'
if [ -z "$FAILED" ]; then
	printf 'all tests passed\n'
	exit 0
fi
printf 'failed:%s\n' "$FAILED"
exit 1

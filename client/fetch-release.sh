#!/bin/sh
# Fetch the seven core client tarballs of a published client-v* release into
# client/out, checksum-verified, so a server build can embed them without
# building the client itself.
#
#   client/fetch-release.sh [client-vX.Y.Z]      (default: the newest client-v*)
#
# This is what the server's release workflow does before build/build.sh: the
# --serve mode hands the device a dropbearmulti for its architecture, so all
# seven have to be inside the rootfs, and a client release that already went
# through client/verify.sh in CI is the build to trust rather than a second,
# unverified compile of the same source.
#
# Environment:
#   DBT_REPO   owner/name            (default: areqq/sshd-tunnel)
#   OUT_DIR    where to put them     (default: client/out)

set -eu

REPO="${DBT_REPO:-areqq/sshd-tunnel}"
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$HERE/out}"
TAG="${1:-}"
ARCHES='x86_64 i686 armv7 armv5 aarch64 mips mipsel'

log() { printf '==> %s\n' "$*"; }
die() { printf 'fetch-release: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die 'need curl'
command -v sha256sum >/dev/null 2>&1 || die 'need sha256sum'

if [ -z "$TAG" ]; then
	log 'looking up the newest client-v* release'
	TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases" \
		| tr ',' '\n' | grep '"tag_name"' | grep 'client-v' | head -1 \
		| sed -e 's/.*"\(client-v[^"]*\)".*/\1/')"
	[ -n "$TAG" ] || die 'cannot determine the newest client-v* release; pass the tag'
fi
case "$TAG" in
	client-v*) ;;
	*) die "not a client release tag: $TAG" ;;
esac

BASE="https://github.com/$REPO/releases/download/$TAG"
mkdir -p "$OUT_DIR"
log "fetching $TAG into $OUT_DIR"

for arch in $ARCHES; do
	name="dropbear-tunnel-$arch.tgz"
	curl -fsSL -o "$OUT_DIR/$name" "$BASE/$name" || die "cannot download $BASE/$name"
	curl -fsSL -o "$OUT_DIR/$name.sha256" "$BASE/$name.sha256" || die "cannot download the checksum for $name"
	( cd "$OUT_DIR" && sha256sum -c --quiet "$name.sha256" ) || die "checksum mismatch for $name"
	printf '    %-32s %8s bytes\n' "$name" "$(wc -c <"$OUT_DIR/$name")"
done
printf '%s\n' "$TAG" > "$OUT_DIR/RELEASE"
log "done: $TAG"

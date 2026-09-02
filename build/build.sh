#!/bin/sh
# Convenience wrapper: runs the real build inside an Alpine container, so the
# host needs nothing but podman or docker.
#
#   build/build.sh
#
# Environment:
#   CONTAINER_ENGINE  podman or docker (auto-detected)
#   ALPINE_IMAGE      builder image      (default: alpine:latest)
#   ARCH              target arch        (default: x86_64)
#   ALPINE_BRANCH     Alpine branch      (default: latest-stable)
#   VERSION           stamped into the VERSION file (default: dev)

set -eu

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE="${ALPINE_IMAGE:-alpine:latest}"

if [ -z "${CONTAINER_ENGINE:-}" ]; then
	if command -v podman >/dev/null 2>&1; then
		CONTAINER_ENGINE='podman'
	elif command -v docker >/dev/null 2>&1; then
		CONTAINER_ENGINE='docker'
	else
		printf 'build.sh: need podman or docker; alternatively run build/build-rootfs.sh as root on an Alpine host\n' >&2
		exit 1
	fi
fi

printf '==> building with %s (%s)\n' "$CONTAINER_ENGINE" "$IMAGE"

exec "$CONTAINER_ENGINE" run --rm \
	-v "$REPO_DIR:/work:z" \
	-w /work \
	-e "ARCH=${ARCH:-x86_64}" \
	-e "ALPINE_BRANCH=${ALPINE_BRANCH:-latest-stable}" \
	-e "VERSION=${VERSION:-dev}" \
	"$IMAGE" \
	sh /work/build/build-rootfs.sh

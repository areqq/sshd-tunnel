#!/bin/sh
# Build a minimal Alpine chroot containing an OpenSSH server configured for
# reverse-tunnel-only access, then package it as a tarball.
#
# Runs INSIDE an Alpine container (or on an Alpine host) as root, because it
# needs apk.static and ownership control over the produced rootfs.
# Use build/build.sh to launch it via podman/docker from any host.
#
# Environment:
#   ARCH            target architecture         (default: x86_64)
#   ALPINE_BRANCH   Alpine branch to install from (default: latest-stable)
#   ALPINE_MIRROR   package mirror              (default: dl-cdn.alpinelinux.org)
#   OUT_DIR         where the tarball is written (default: <repo>/dist)

set -eu

ARCH="${ARCH:-x86_64}"
ALPINE_BRANCH="${ALPINE_BRANCH:-latest-stable}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"

REPO_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_DIR/dist}"
STAGE_DIR="$OUT_DIR/stage"
ROOTFS="$STAGE_DIR/sshd-tunel/rootfs"
TARBALL="$OUT_DIR/sshd-tunel-$ARCH.tgz"

TCP_UID=1000
TCP_GID=1000

log() { printf '==> %s\n' "$*"; }
die() { printf 'build-rootfs: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die 'must run as root (use build/build.sh to run it in a container)'

# ---------------------------------------------------------------- apk.static
if ! command -v apk.static >/dev/null 2>&1; then
	log 'installing apk-tools-static'
	apk add --no-cache apk-tools-static >/dev/null || die 'cannot install apk-tools-static'
fi
APK_STATIC="$(command -v apk.static)"

# ------------------------------------------------------------- package list
PACKAGES="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$REPO_DIR/build/packages.txt" | tr '\n' ' ')"
[ -n "$PACKAGES" ] || die 'build/packages.txt yielded no packages'
log "packages: $PACKAGES"

# ------------------------------------------------------------------ bootstrap
rm -rf "$STAGE_DIR"
mkdir -p "$ROOTFS/etc/apk/keys"

# Copy the host's Alpine signing keys into the new root so package signatures
# are verified; this is why --allow-untrusted is not used below.
cp /etc/apk/keys/* "$ROOTFS/etc/apk/keys/" 2>/dev/null || die 'no Alpine signing keys on the build host'

MAIN_REPO="$ALPINE_MIRROR/$ALPINE_BRANCH/main"
COMMUNITY_REPO="$ALPINE_MIRROR/$ALPINE_BRANCH/community"

log "bootstrapping $ARCH rootfs from $ALPINE_BRANCH"
# shellcheck disable=SC2086
"$APK_STATIC" --arch "$ARCH" \
	-X "$MAIN_REPO" -X "$COMMUNITY_REPO" \
	-U --root "$ROOTFS" --initdb \
	add $PACKAGES

printf '%s\n%s\n' "$MAIN_REPO" "$COMMUNITY_REPO" > "$ROOTFS/etc/apk/repositories"

# --------------------------------------------------------------------- user
# Written directly instead of running adduser under chroot, so the build stays
# deterministic and needs no working /dev inside the rootfs.
log "creating unprivileged tunnel account 'tcp' (uid $TCP_UID)"
grep -q '^tcp:' "$ROOTFS/etc/group" || printf 'tcp:x:%s:\n' "$TCP_GID" >> "$ROOTFS/etc/group"
grep -q '^tcp:' "$ROOTFS/etc/passwd" || \
	printf 'tcp:x:%s:%s:reverse tunnel account:/home/tcp:/bin/sh\n' "$TCP_UID" "$TCP_GID" >> "$ROOTFS/etc/passwd"
# '!' as the password hash means "locked": no password will ever match. run.sh
# replaces it only when a password is supplied on the command line.
grep -q '^tcp:' "$ROOTFS/etc/shadow" 2>/dev/null || \
	printf 'tcp:!:20000:0:99999:7:::\n' >> "$ROOTFS/etc/shadow"

# Alpine ships root with an *empty* password field, which means "no password
# required" rather than "no login". sshd refuses root anyway, but an empty
# hash inside a chroot is not something to leave lying around.
sed -i 's|^root::|root:!:|' "$ROOTFS/etc/shadow"
chmod 640 "$ROOTFS/etc/shadow"

mkdir -p "$ROOTFS/home/tcp/.ssh"
: > "$ROOTFS/home/tcp/.ssh/authorized_keys"
chown -R "$TCP_UID:$TCP_GID" "$ROOTFS/home/tcp"
chmod 700 "$ROOTFS/home/tcp/.ssh"
chmod 600 "$ROOTFS/home/tcp/.ssh/authorized_keys"

# ------------------------------------------------------------------ overlay
log 'applying rootfs-overlay'
cp -a "$REPO_DIR/rootfs-overlay/." "$ROOTFS/"
chmod 755 "$ROOTFS/run.sh" "$ROOTFS/usr/local/bin/tunnel-only"
chmod 644 "$ROOTFS/etc/ssh/sshd_config.tmpl"

# --------------------------------------------------------- runtime directories
# /var/empty is sshd's privilege separation directory and must be owned by root
# and not writable by anyone else, or sshd refuses to start.
mkdir -p "$ROOTFS/var/empty" "$ROOTFS/run" "$ROOTFS/srv/www" "$ROOTFS/tmp" \
	"$ROOTFS/proc" "$ROOTFS/dev" "$ROOTFS/var/log"
chown root:root "$ROOTFS/var/empty"
chmod 755 "$ROOTFS/var/empty"
chmod 1777 "$ROOTFS/tmp"

# /dev is emptied and refilled with placeholder regular files; the host wrapper
# bind-mounts the real devices onto them at startup. Device nodes must not
# survive into the tarball, because unpacking one needs mknod privileges and
# the whole point is that `curl | sh` works as a normal user.
#
# The directory is deleted rather than overwritten in place: apk creates
# initial device nodes for busybox, and redirecting into an existing character
# device writes *through* it instead of replacing the file. That is what
# shipped a broken v0.1.0 — locally mknod was denied so the bug stayed hidden,
# while the CI builder had CAP_MKNOD and produced real nodes.
rm -rf "$ROOTFS/dev"
mkdir -p "$ROOTFS/dev"
chmod 755 "$ROOTFS/dev"
for dev in null zero full random urandom tty; do
	: > "$ROOTFS/dev/$dev"
done

# ---------------------------------------------------------------------- strip
log 'stripping build leftovers'
rm -rf "$ROOTFS/var/cache/apk"/* \
	"$ROOTFS/usr/share/man" \
	"$ROOTFS/usr/share/doc" \
	"$ROOTFS/usr/share/info" \
	"$ROOTFS/usr/share/i18n" \
	"$ROOTFS/etc/apk/cache"
find "$ROOTFS" -name '*.a' -type f -delete
find "$ROOTFS" -name '*.la' -type f -delete
mkdir -p "$ROOTFS/var/cache/apk"

# ------------------------------------------------------------------ validate
"$REPO_DIR/build/verify-rootfs.sh" "$ROOTFS"

# ------------------------------------------------------------------- version
OPENSSH_VER="$(awk -F'[ -]' '/^P:openssh-server$/{found=1} found&&/^V:/{print $2; exit}' "$ROOTFS/lib/apk/db/installed" 2>/dev/null || true)"
[ -n "$OPENSSH_VER" ] || OPENSSH_VER='unknown'
{
	printf 'name:           sshd-tunel\n'
	printf 'version:        %s\n' "${VERSION:-dev}"
	printf 'built:          %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'arch:           %s\n' "$ARCH"
	printf 'alpine_branch:  %s\n' "$ALPINE_BRANCH"
	printf 'openssh:        %s\n' "$OPENSSH_VER"
	printf '\npackages:\n'
	awk '/^P:/{p=substr($0,3)} /^V:/{print "  " p " " substr($0,3)}' "$ROOTFS/lib/apk/db/installed" | sort
} > "$STAGE_DIR/sshd-tunel/VERSION"

# ------------------------------------------------------------------- package
log 'assembling tarball'
cp "$REPO_DIR/run" "$STAGE_DIR/sshd-tunel/run"
chmod 755 "$STAGE_DIR/sshd-tunel/run"
cp "$REPO_DIR/README.md" "$STAGE_DIR/sshd-tunel/README.md"

mkdir -p "$OUT_DIR"
rm -f "$TARBALL"
tar czf "$TARBALL" -C "$STAGE_DIR" sshd-tunel
( cd "$OUT_DIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

log "rootfs:  $(du -sh "$ROOTFS" | cut -f1)"
log "tarball: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
log 'done'

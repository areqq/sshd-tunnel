#!/bin/sh
# Fail the build if the produced rootfs is not what sshd-tunnel needs.
#
#   build/verify-rootfs.sh <rootfs>
#
# The important check is the legacy algorithm gate. OpenSSH validates
# algorithm names while parsing sshd_config, before it loads host keys, so a
# config naming an algorithm the binary no longer supports is rejected
# outright ("Bad SSH2 KexAlgorithms", "Bad key types"). Rendering the real
# template and asking sshd to parse it therefore proves that every legacy
# algorithm the template asks for still exists in this build — which is
# exactly what a Dropbear client from 2014 depends on.

set -eu

ROOTFS="${1:?usage: verify-rootfs.sh <rootfs>}"
FAILURES=0

# Algorithms a Dropbear 2014.x client can actually negotiate. If a future
# OpenSSH drops one of these, the build stops here instead of shipping a
# server the old client cannot talk to.
REQUIRED_ALGOS='diffie-hellman-group14-sha1 diffie-hellman-group1-sha1 ssh-rsa hmac-sha1 aes128-cbc 3des-cbc'

# Settings that keep the account restricted to reverse forwards.
REQUIRED_SETTINGS='AllowTcpForwarding=remote PermitOpen=none GatewayPorts=yes PermitTTY=no X11Forwarding=no AllowAgentForwarding=no PermitRootLogin=no AllowUsers=tcp'

ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
head_() { printf '\n-- %s\n' "$*"; }

[ -d "$ROOTFS" ] || { printf 'verify-rootfs: no such rootfs: %s\n' "$ROOTFS" >&2; exit 1; }

head_ 'required files'
for f in \
	run.sh \
	vpn.sh \
	usr/sbin/sshd \
	usr/sbin/openvpn \
	usr/bin/ssh-keygen \
	usr/bin/dropbearconvert \
	bin/busybox-extras \
	bin/sh \
	usr/local/bin/tunnel-only \
	usr/local/share/sshd-tunnel/bootstrap-body.sh \
	usr/local/share/sshd-tunnel/vpn-body.sh \
	etc/ssh/sshd_config.tmpl
do
	if [ -e "$ROOTFS/$f" ]; then ok "$f"; else bad "missing $f"; fi
done

for f in run.sh vpn.sh usr/local/bin/tunnel-only; do
	[ -x "$ROOTFS/$f" ] || bad "$f is not executable"
done

head_ 'tunnel account'
grep -q '^tcp:' "$ROOTFS/etc/passwd" && ok 'tcp in /etc/passwd' || bad 'tcp missing from /etc/passwd'
grep -q '^tcp:' "$ROOTFS/etc/group"  && ok 'tcp in /etc/group'  || bad 'tcp missing from /etc/group'
grep -q '^tcp:!' "$ROOTFS/etc/shadow" && ok 'tcp password locked by default' || bad 'tcp is not locked in /etc/shadow'
if grep -qE '^root:[!*]' "$ROOTFS/etc/shadow"; then
	ok 'root is locked'
else
	bad "root is not locked: $(grep '^root:' "$ROOTFS/etc/shadow")"
fi

head_ 'sshd privilege separation directory'
if [ -d "$ROOTFS/var/empty" ]; then
	perms="$(stat -c '%a %U' "$ROOTFS/var/empty" 2>/dev/null || echo '? ?')"
	case "$perms" in
		'755 root') ok "/var/empty ($perms)" ;;
		*) bad "/var/empty must be 755 root, is $perms" ;;
	esac
else
	bad '/var/empty is missing (sshd will refuse to start)'
fi

head_ 'device placeholders'
for dev in null zero full random urandom tty net/tun; do
	if [ -f "$ROOTFS/dev/$dev" ]; then
		ok "dev/$dev is a placeholder file"
	elif [ -e "$ROOTFS/dev/$dev" ]; then
		bad "dev/$dev exists but is not a regular file"
	else
		bad "dev/$dev placeholder missing"
	fi
done

# A device node anywhere in the rootfs makes the tarball impossible to unpack
# without mknod privileges, which breaks `curl | sh` for a normal user. apk
# creates such nodes for busybox, so this is checked rather than assumed.
NODES="$(find "$ROOTFS" \( -type c -o -type b \) 2>/dev/null)"
if [ -z "$NODES" ]; then
	ok 'the rootfs contains no device nodes'
else
	bad 'the rootfs contains device nodes'
	printf '%s\n' "$NODES" | sed 's/^/        /'
fi

head_ 'legacy algorithms named in the config template'
for algo in $REQUIRED_ALGOS; do
	if grep -q -- "$algo" "$ROOTFS/etc/ssh/sshd_config.tmpl"; then
		ok "$algo"
	else
		bad "$algo is not requested by sshd_config.tmpl"
	fi
done

head_ 'tunnel-only restrictions in the config template'
for setting in $REQUIRED_SETTINGS; do
	key="${setting%%=*}"
	value="${setting#*=}"
	if grep -qE "^[[:space:]]*$key[[:space:]]+$value([[:space:]]|\$)" "$ROOTFS/etc/ssh/sshd_config.tmpl"; then
		ok "$key $value"
	else
		bad "expected '$key $value' in sshd_config.tmpl"
	fi
done
grep -qE '^[[:space:]]*ForceCommand[[:space:]]+/usr/local/bin/tunnel-only' "$ROOTFS/etc/ssh/sshd_config.tmpl" \
	&& ok 'ForceCommand tunnel-only' || bad 'ForceCommand is not set to tunnel-only'

head_ 'sshd accepts the rendered config'
# Runs the real code path: /run.sh renders the template and hands it to
# `sshd -t`, which rejects any algorithm this binary no longer supports.
if CHECK_OUT="$(env -i \
		PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
		HOME=/root TERM=dumb \
		chroot "$ROOTFS" /run.sh 2222 --check-config 2>&1)"
then
	ok 'sshd parsed the rendered config'
	# An unknown directive is only a warning, so it would otherwise ship and
	# be printed on every single start.
	case "$CHECK_OUT" in
		*'Unsupported option'*|*'Deprecated option'*)
			bad 'the config names options this sshd does not support' ;;
		*)  ok 'no unsupported or deprecated options' ;;
	esac
	# Proof the legacy names survived into the lists sshd will actually offer,
	# not merely into the config file.
	for algo in $REQUIRED_ALGOS; do
		case "$CHECK_OUT" in
			*"$algo"*) ok "$algo is in the effective algorithm list" ;;
			*)         bad "$algo did not reach the effective algorithm list" ;;
		esac
	done
	printf '%s\n' "$CHECK_OUT" | sed 's/^/        /'
else
	bad 'sshd rejected the rendered config'
	printf '%s\n' "$CHECK_OUT" | sed 's/^/        /'
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
	printf 'verify-rootfs: all checks passed\n'
	exit 0
fi
printf 'verify-rootfs: %s check(s) failed\n' "$FAILURES" >&2
exit 1

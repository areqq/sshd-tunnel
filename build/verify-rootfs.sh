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
	dsvpn.sh \
	usr/sbin/sshd \
	usr/sbin/sslh-select \
	usr/sbin/openvpn \
	usr/bin/ssh-keygen \
	usr/bin/dropbearconvert \
	bin/busybox-extras \
	bin/sh \
	usr/local/bin/tunnel-only \
	usr/local/bin/patch-cred \
	usr/local/share/sshd-tunnel/bootstrap-body.sh \
	usr/local/share/sshd-tunnel/serve-body.sh \
	usr/local/share/sshd-tunnel/vpn-body.sh \
	usr/local/share/sshd-tunnel/dsvpn-body.sh \
	etc/ssh/sshd_config.tmpl
do
	if [ -e "$ROOTFS/$f" ]; then ok "$f"; else bad "missing $f"; fi
done

for f in run.sh vpn.sh dsvpn.sh usr/local/bin/tunnel-only usr/local/bin/patch-cred; do
	[ -x "$ROOTFS/$f" ] || bad "$f is not executable"
done

# --------------------------------------------------------------- dsvpn binaries
# Absent is allowed: a rootfs built without vpn-client/out simply has no
# --dsvpn mode. Half-present is not — a device whose architecture is missing
# would fetch a 404 and be told the server was misbuilt, which is exactly the
# failure this catches at build time instead.
head_ 'dsvpn binaries for the --dsvpn mode'
DSVPN_DIR="$ROOTFS/usr/local/share/sshd-tunnel/dsvpn"
if [ ! -d "$DSVPN_DIR" ]; then
	ok 'not embedded (--dsvpn will be unavailable, which /dsvpn.sh reports)'
else
	for dsv_arch in x86_64 i686 armv7 armv5 aarch64 mips mipsel; do
		dsv_bin="$DSVPN_DIR/dsvpn-$dsv_arch"
		if [ ! -f "$dsv_bin" ]; then
			bad "missing dsvpn-$dsv_arch"
		elif [ ! -x "$dsv_bin" ]; then
			bad "dsvpn-$dsv_arch is not executable"
		else
			ok "dsvpn-$dsv_arch ($(wc -c <"$dsv_bin") bytes)"
		fi
	done
	# The server runs one of these itself, so at least the native one has to be
	# a working binary and not, say, a truncated download.
	if "$DSVPN_DIR/dsvpn-$(uname -m | sed -e 's/^amd64$/x86_64/' -e 's/^arm64$/aarch64/')" 2>&1 |
		grep -q DSVPN
	then
		ok 'the native dsvpn binary runs'
	else
		bad 'the native dsvpn binary does not run'
	fi
fi

# ------------------------------------------------------------ dropbear binaries
# Same rule as the dsvpn set: all seven or none.
head_ 'dropbear binaries for the --serve mode'
DBT_DIR="$ROOTFS/usr/local/share/sshd-tunnel/dropbear"
if [ ! -d "$DBT_DIR" ]; then
	ok 'not embedded (--serve will be unavailable, which /run.sh reports)'
else
	for dbt_arch in x86_64 i686 armv7 armv5 aarch64 mips mipsel; do
		dbt_bin="$DBT_DIR/dropbearmulti-$dbt_arch"
		if [ ! -f "$dbt_bin" ]; then
			bad "missing dropbearmulti-$dbt_arch"
		elif [ ! -x "$dbt_bin" ]; then
			bad "dropbearmulti-$dbt_arch is not executable"
		elif ! strings -t d -- "$dbt_bin" | grep -q '@@DBCRED:id:B@@'; then
			# Without the slots there is nothing for /run.sh to patch, so this is
			# a plain upstream Dropbear and not the client this project ships.
			bad "dropbearmulti-$dbt_arch has no credential slots"
		else
			ok "dropbearmulti-$dbt_arch ($(wc -c <"$dbt_bin") bytes)"
		fi
	done
	[ -f "$DBT_DIR/RELEASE" ] && ok "from client release $(cat "$DBT_DIR/RELEASE")"
	# /run.sh runs the native one for dropbearkey, so it has to actually work.
	if "$DBT_DIR/dropbearmulti-$(uname -m | sed -e 's/^amd64$/x86_64/' -e 's/^arm64$/aarch64/')" 2>&1 |
		grep -q Dropbear
	then
		ok 'the native dropbearmulti runs'
	else
		bad 'the native dropbearmulti does not run'
	fi
	# patch-cred has to work with the chroot's own busybox, which has no
	# `grep -b`; this runs it there on a scratch copy, the way /run.sh will.
	if cp "$DBT_DIR/dropbearmulti-x86_64" "$ROOTFS/tmp/.verify-dbm" 2>/dev/null \
		&& printf 'ssh-ed25519 AAAA verify\n' > "$ROOTFS/tmp/.verify-ak" \
		&& chroot "$ROOTFS" /usr/local/bin/patch-cred /tmp/.verify-dbm ak /tmp/.verify-ak >/dev/null 2>&1 \
		&& strings -- "$ROOTFS/tmp/.verify-dbm" | grep -q '@@DBCRED:ak:B@@c3NoLWVkMjU1MTkgQUFBQSB2ZXJpZnkK'
	then
		ok 'patch-cred works inside the chroot'
	else
		bad 'patch-cred does not work inside the chroot'
	fi
	rm -f "$ROOTFS/tmp/.verify-dbm" "$ROOTFS/tmp/.verify-ak"
fi

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

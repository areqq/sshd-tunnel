#!/bin/sh
# sshd-tunnel entrypoint, executed INSIDE the chroot.
#
#   /run.sh <port> [password] [options]
#
# Starts an OpenSSH server that accepts exactly one thing: a reverse TCP
# forward (-R) from the account 'tcp'. Authentication is either password-only
# (password given on the command line) or public-key-only (no password given,
# in which case a fresh key pair is generated and printed at every start).
#
# With --serve the device end is supplied too: the one-liner hands the device
# a static dropbearmulti for its architecture with three credentials patched
# in (the identity it dials out with, a host key for its own SSH server, and
# the public key that server accepts), the device starts that server on its
# loopback and exposes it through the tunnel, and the operator logs into the
# device from here with the matching private key. Nothing has to exist on the
# device beyond a shell and wget or curl.
#
# Named /run.sh rather than /run because /run must stay a directory: OpenSSH
# keeps its pid file there. The host-side wrapper is called 'run', so the
# user-facing command is still `./run <port>`.
#
# Environment:
#   SSHD_TUNNEL_PASSWORD   password, as an alternative to argument 2 (keeps it
#                          out of the host's process list)
#   SSHD_TUNNEL_IP         space-separated server addresses to advertise; when
#                          unset they are detected from the interfaces

set -eu

PROG='sshd-tunnel'
HOST_KEY='/etc/ssh/ssh_host_rsa_key'
CONFIG_TMPL='/etc/ssh/sshd_config.tmpl'
CONFIG='/etc/ssh/sshd_config.active'
BOOTSTRAP_BODY='/usr/local/share/sshd-tunnel/bootstrap-body.sh'
SERVE_BODY='/usr/local/share/sshd-tunnel/serve-body.sh'
DBT_BIN_DIR='/usr/local/share/sshd-tunnel/dropbear'
WEB_ROOT='/srv/www'
RUNTIME_DIR='/run/sshd-tunnel'
CLIENT_KEY="$RUNTIME_DIR/client_key"
# --serve: the device's identity and host key (Dropbear format, patched into
# the binary) and the operator's key for logging into the device (OpenSSH
# format, used from the host).
ID_KEY="$RUNTIME_DIR/id.db"
HK_KEY="$RUNTIME_DIR/hk.db"
DEVICE_KEY="$RUNTIME_DIR/device_key"

PORT=''
PASSWORD="${SSHD_TUNNEL_PASSWORD:-}"
HTTP_PORT=''
HTTP_ENABLED=1
PERMIT_LISTEN='*:*'
EXPOSE='10022:127.0.0.1:22'
EXPOSE_SET=0
KEY_TYPE='rsa2048'
CHECK_ONLY=0
SERVE=0

HTTPD_PID=''
SSHD_PID=''
TOKEN=''

log()  { printf '%s: %s\n' "$PROG" "$*" >&2; }
die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

# Wrap a value in single quotes for safe inclusion in generated shell code.
# Used instead of substituting values into a template with sed, because a
# password may legitimately contain quotes, backslashes or sed delimiters.
shquote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

usage() {
	cat <<EOF
Usage: /run.sh <port> [password] [options]

  <port>              TCP port for sshd, bound on every interface
  [password]          enable password-only auth for user 'tcp'
                      (omit for key-only auth with a freshly generated key)

Options:
  --no-http           do not serve the bootstrap script over HTTP
  --http <port>       port for the bootstrap HTTP server (default: <port>+1)
  --listen <patterns> PermitListen value limiting which ports the client may
                      open with -R, e.g. '10022' or '10022 5900'
                      (default: *:*, meaning any port)
  --expose <r:h:p>    reverse mapping baked into the bootstrap script:
                      server port : device host : device port
                      (default: 10022:127.0.0.1:22)
  --key-type <type>   client key to generate, one of rsa2048, rsa3072,
                      rsa4096, ecdsa256, ecdsa384, ecdsa521
                      (default: rsa2048; ignored in password mode)
  --serve             also give the device an SSH server: the one-liner
                      fetches a static Dropbear for its architecture with the
                      credentials already inside, starts it on the device's
                      loopback and exposes it through the tunnel, so you can
                      log into the device from here. Key mode only; the
                      default --expose becomes 10022:127.0.0.1:2222
  --check-config      render and validate the sshd config, then exit
  -h, --help          this text
EOF
}

# --------------------------------------------------------------- argument parsing
[ $# -gt 0 ] || { usage; exit 2; }
case "$1" in
	-h|--help) usage; exit 0 ;;
esac

PORT="$1"
shift

# A second positional argument is the password. Anything starting with '-' is
# an option, so passwords beginning with '-' must go through the environment.
case "${1:-}" in
	''|-*) ;;
	*) PASSWORD="$1"; shift ;;
esac

while [ $# -gt 0 ]; do
	case "$1" in
		--no-http)      HTTP_ENABLED=0 ;;
		--http)         [ $# -ge 2 ] || die '--http needs a port'; HTTP_PORT="$2"; shift ;;
		--listen)       [ $# -ge 2 ] || die '--listen needs a value'; PERMIT_LISTEN="$2"; shift ;;
		--expose)       [ $# -ge 2 ] || die '--expose needs r:h:p'; EXPOSE="$2"; EXPOSE_SET=1; shift ;;
		--key-type)     [ $# -ge 2 ] || die '--key-type needs a type'; KEY_TYPE="$2"; shift ;;
		--serve)        SERVE=1 ;;
		--check-config) CHECK_ONLY=1; HTTP_ENABLED=0 ;;
		-h|--help)      usage; exit 0 ;;
		*)              die "unknown option: $1" ;;
	esac
	shift
done

is_port() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_port "$PORT" || die "invalid port: $PORT"

if [ "$SERVE" -eq 1 ]; then
	[ -z "$PASSWORD" ] || die '--serve authenticates with the identity embedded in the device binary; it cannot be combined with a password'
	[ "$HTTP_ENABLED" -eq 1 ] || die '--serve needs the HTTP server: that is how the device fetches its binary'
	# The device's SSH server listens on its loopback; 22 would collide with
	# whatever the device already runs there.
	[ "$EXPOSE_SET" -eq 1 ] || EXPOSE='10022:127.0.0.1:2222'
fi

if [ -z "$HTTP_PORT" ]; then
	HTTP_PORT=$((PORT + 1))
	[ "$HTTP_PORT" -le 65535 ] || die "cannot derive an HTTP port from $PORT; pass --http"
fi
is_port "$HTTP_PORT" || die "invalid HTTP port: $HTTP_PORT"
[ "$HTTP_PORT" -ne "$PORT" ] || die 'the HTTP port must differ from the sshd port'

# --expose is r:h:p — server-side port, then the address:port on the device.
EXPOSE_RPORT="${EXPOSE%%:*}"
EXPOSE_REST="${EXPOSE#*:}"
EXPOSE_LHOST="${EXPOSE_REST%:*}"
EXPOSE_LPORT="${EXPOSE_REST##*:}"
case "$EXPOSE" in
	*:*:*) ;;
	*) die "--expose must look like rport:host:port, got: $EXPOSE" ;;
esac
is_port "$EXPOSE_RPORT" || die "invalid reverse port in --expose: $EXPOSE_RPORT"
is_port "$EXPOSE_LPORT" || die "invalid device port in --expose: $EXPOSE_LPORT"
[ -n "$EXPOSE_LHOST" ] || die '--expose is missing the device host'

# Only types a Dropbear 2014 client can actually use are offered. ssh-dss is
# out because OpenSSH 10 removed it from the server side, and ed25519 is out
# because Dropbear did not gain it until 2020.79 — and because it cannot be
# written in the PEM form that a 2014 dropbearconvert is able to read.
case "$KEY_TYPE" in
	rsa2048)   KEY_ALGO='rsa';   KEY_BITS=2048 ;;
	rsa3072)   KEY_ALGO='rsa';   KEY_BITS=3072 ;;
	rsa4096)   KEY_ALGO='rsa';   KEY_BITS=4096 ;;
	ecdsa256)  KEY_ALGO='ecdsa'; KEY_BITS=256 ;;
	ecdsa384)  KEY_ALGO='ecdsa'; KEY_BITS=384 ;;
	ecdsa521)  KEY_ALGO='ecdsa'; KEY_BITS=521 ;;
	*) die "unknown --key-type: $KEY_TYPE (expected rsa2048, rsa3072, rsa4096, ecdsa256, ecdsa384 or ecdsa521)" ;;
esac

if [ -n "$PASSWORD" ]; then
	AUTH_MODE='password'
	PASSWORD_AUTH='yes'
	PUBKEY_AUTH='no'
else
	AUTH_MODE='key'
	PASSWORD_AUTH='no'
	PUBKEY_AUTH='yes'
fi

# ------------------------------------------------------------------- cleanup
cleanup() {
	trap - EXIT INT TERM HUP
	[ -n "$HTTPD_PID" ] && kill "$HTTPD_PID" 2>/dev/null || true
	[ -n "$SSHD_PID" ] && kill "$SSHD_PID" 2>/dev/null || true
	# The private keys and the tokenised URL must not outlive the process that
	# published them.
	[ -n "$TOKEN" ] && rm -rf "$WEB_ROOT/t/$TOKEN" || true
	rm -f "$CLIENT_KEY" "$CLIENT_KEY.pub" "$ID_KEY" "$ID_KEY.pub" "$HK_KEY" \
		"$DEVICE_KEY" "$DEVICE_KEY.pub" 2>/dev/null || true
}

# ---------------------------------------------------------------- sanity checks
[ -f "$CONFIG_TMPL" ] || die "missing $CONFIG_TMPL"
[ -x /usr/sbin/sshd ] || die 'sshd not found in the chroot'

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

# The tarball may have been unpacked by a normal user, in which case every
# file belongs to that uid. sshd enforces StrictModes on its privilege
# separation directory and on the path to authorized_keys, and refuses to
# start otherwise, so ownership is restored here rather than being demanded
# of whoever unpacked the release.
chown root:root / /etc /etc/ssh /var /var/empty 2>/dev/null || true
chmod 755 / /var/empty 2>/dev/null || true

render_config() {
	sed \
		-e "s|@PORT@|$PORT|g" \
		-e "s|@HOST_KEY@|$HOST_KEY|g" \
		-e "s|@PASSWORD_AUTH@|$PASSWORD_AUTH|g" \
		-e "s|@PUBKEY_AUTH@|$PUBKEY_AUTH|g" \
		-e "s|@PERMIT_LISTEN@|$PERMIT_LISTEN|g" \
		"$CONFIG_TMPL" > "$CONFIG"
	chmod 600 "$CONFIG"
}

# Everything below needs randomness: host key, client key and the HTTP token.
HAVE_RANDOM=0
[ -c /dev/urandom ] && HAVE_RANDOM=1

# --------------------------------------------------------------- config check
# --check-config runs at build time, inside a container where /dev holds only
# placeholder files, so it must cope with having no host key to point at.
if [ "$CHECK_ONLY" -eq 1 ]; then
	# A throwaway host key, never the real one: a key generated here would be
	# baked into the release tarball and shared by every installation.
	HOST_KEY="$RUNTIME_DIR/check_host_key"
	rm -f "$HOST_KEY" "$HOST_KEY.pub"
	render_config
	# ssh-keygen draws from getrandom(2), so this succeeds even in a build
	# container where /dev/urandom is only a placeholder file.
	ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -C 'config check' -f "$HOST_KEY" 2>/dev/null || true
	if [ -f "$HOST_KEY" ]; then
		/usr/sbin/sshd -t -f "$CONFIG" || die "the rendered config in $CONFIG is not valid"
	else
		# Algorithm names are validated while parsing, before host keys are
		# loaded, so "no hostkeys available" is proof the rest was accepted.
		CHECK_OUT="$(/usr/sbin/sshd -t -f "$CONFIG" 2>&1 || true)"
		case "$CHECK_OUT" in
			*'no hostkeys available'*)
				log 'config accepted (no host key yet, as expected at build time)' ;;
			'') log 'config accepted' ;;
			*)  die "config rejected: $CHECK_OUT" ;;
		esac
	fi
	log 'effective settings:'
	/usr/sbin/sshd -T -f "$CONFIG" 2>/dev/null | \
		grep -Ei '^(kexalgorithms|ciphers|macs|hostkeyalgorithms|pubkeyacceptedalgorithms|permitlisten|gatewayports|allowtcpforwarding|passwordauthentication|pubkeyauthentication) ' \
		|| log '(sshd -T needs a host key; skipped)'
	# Leave nothing behind that would end up in the release tarball.
	rm -f "$HOST_KEY" "$HOST_KEY.pub" "$CONFIG"
	exit 0
fi

[ "$HAVE_RANDOM" -eq 1 ] || \
	die '/dev/urandom is not a device node inside the chroot; use the run wrapper, or bind-mount it yourself'

# ----------------------------------------------------------- --serve preflight
# The device binaries are embedded at build time, from a client release. Their
# absence is a build without them, not a runtime condition to work around.
DBM=''
if [ "$SERVE" -eq 1 ]; then
	[ -f "$SERVE_BODY" ] || die "missing $SERVE_BODY"
	[ -x /usr/local/bin/patch-cred ] || die 'missing /usr/local/bin/patch-cred'
	[ -d "$DBT_BIN_DIR" ] || die "missing $DBT_BIN_DIR — this rootfs was built without the dropbear client binaries (client/fetch-release.sh, then rebuild)"
	# The keys are generated with the client's own dropbearkey, out of the same
	# set that is served to devices: one build to trust and one to test.
	case "$(uname -m)" in
		x86_64|amd64)      HOST_ARCH='x86_64' ;;
		i[3456]86)         HOST_ARCH='i686' ;;
		aarch64|arm64)     HOST_ARCH='aarch64' ;;
		armv7*|armv8l)     HOST_ARCH='armv7' ;;
		armv6*|armv5*|arm) HOST_ARCH='armv5' ;;
		*) die "no dropbear build for this server's architecture: $(uname -m)" ;;
	esac
	DBM="$DBT_BIN_DIR/dropbearmulti-$HOST_ARCH"
	[ -x "$DBM" ] || die "missing $DBM"
	"$DBM" 2>&1 | grep -q Dropbear || die "$DBM does not run here"
fi

# -------------------------------------------------------------- host key
# Persistent on purpose: a Dropbear client that stores host keys would flag a
# changed fingerprint on every restart otherwise.
if [ ! -f "$HOST_KEY" ]; then
	log 'generating a persistent RSA host key (first start)'
	ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -C "$PROG host key" -f "$HOST_KEY"
fi
chmod 600 "$HOST_KEY"
HOST_FP="$(ssh-keygen -l -f "$HOST_KEY" 2>/dev/null | awk '{print $2}')"
HOST_FP_MD5="$(ssh-keygen -l -E md5 -f "$HOST_KEY" 2>/dev/null | awk '{print $2}')"

render_config
/usr/sbin/sshd -t -f "$CONFIG" || die "the rendered config in $CONFIG is not valid"

trap cleanup EXIT INT TERM HUP

# ------------------------------------------------------------------- credentials
AUTHORIZED_KEYS='/home/tcp/.ssh/authorized_keys'
mkdir -p /home/tcp/.ssh

if [ "$AUTH_MODE" = 'password' ]; then
	# Public keys stay unusable in password mode, so any key left over from an
	# earlier key-mode start is removed rather than merely ignored.
	: > "$AUTHORIZED_KEYS"
	printf 'tcp:%s\n' "$PASSWORD" | chpasswd -c sha512
	log 'password authentication enabled for user tcp'
	[ "$KEY_TYPE" = 'rsa2048' ] || log "--key-type $KEY_TYPE ignored: no client key is generated in password mode"
else
	# The account gets a hash of a random string that is immediately
	# discarded, rather than the conventional '!'. OpenSSH treats a shadow
	# entry starting with '!' or '*' as a *locked account* and refuses it
	# outright — including for public-key authentication, which would make
	# key mode impossible. An unknowable hash blocks passwords just as
	# effectively while leaving the account usable.
	printf 'tcp:%s\n' "$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')" | chpasswd -c sha512

	# 'restrict' turns everything off, then port-forwarding is added back: the
	# key is useless for anything but the forward, even if sshd_config changed.
	KEY_OPTS='restrict,port-forwarding'
	for pattern in $PERMIT_LISTEN; do
		KEY_OPTS="$KEY_OPTS,permitlisten=\"$pattern\""
	done

	rm -f "$CLIENT_KEY" "$CLIENT_KEY.pub" "$ID_KEY" "$ID_KEY.pub" "$HK_KEY" "$DEVICE_KEY" "$DEVICE_KEY.pub"
	if [ "$SERVE" -eq 1 ]; then
		# Three keys, none of which ever has to be typed or copied by hand:
		#   id  the device's identity towards this server — Dropbear's own
		#       format, generated by the same binary that will use it, and
		#       patched into that binary rather than fetched as a file;
		#   hk  the host key the device's SSH server presents, same format;
		#   dk  the operator's key for logging into the device, OpenSSH
		#       format because it is used from the host with ssh. Its public
		#       half is the one line the device's server accepts.
		"$DBM" dropbearkey -t ed25519 -f "$ID_KEY" >/dev/null 2>&1 || die 'dropbearkey failed to generate the device identity'
		"$DBM" dropbearkey -y -f "$ID_KEY" 2>/dev/null | grep '^ssh-ed25519 ' > "$ID_KEY.pub"
		[ -s "$ID_KEY.pub" ] || die 'cannot read the public half of the device identity'
		printf '%s %s\n' "$KEY_OPTS" "$(cat "$ID_KEY.pub")" > "$AUTHORIZED_KEYS"

		"$DBM" dropbearkey -t ed25519 -f "$HK_KEY" >/dev/null 2>&1 || die 'dropbearkey failed to generate the device host key'
		DEVICE_HOST_FP="$("$DBM" dropbearkey -y -f "$HK_KEY" 2>/dev/null | sed -n 's/^Fingerprint: //p')"

		ssh-keygen -q -t ed25519 -N '' -C "$PROG device access key" -f "$DEVICE_KEY"
		chmod 600 "$DEVICE_KEY"
		[ "$KEY_TYPE" = 'rsa2048' ] || log "--key-type $KEY_TYPE ignored: --serve embeds an ed25519 identity"
		log 'public-key authentication enabled for user tcp (fresh ed25519 identity, embedded in the device binary)'
	else
		# PEM rather than the native OpenSSH format: the dropbearconvert shipped
		# with a 2014 device can only read PEM, which matters for anyone doing
		# the conversion by hand instead of fetching the pre-converted key.
		ssh-keygen -q -t "$KEY_ALGO" -b "$KEY_BITS" -m PEM -N '' \
			-C "$PROG client key" -f "$CLIENT_KEY"
		printf '%s %s\n' "$KEY_OPTS" "$(cat "$CLIENT_KEY.pub")" > "$AUTHORIZED_KEYS"
		log "public-key authentication enabled for user tcp (fresh $KEY_TYPE key)"
	fi
fi

chown -R tcp:tcp /home/tcp
chmod 700 /home/tcp/.ssh
chmod 600 "$AUTHORIZED_KEYS"

# ------------------------------------------------------------- server addresses
if [ -n "${SSHD_TUNNEL_IP:-}" ]; then
	SERVER_IPS="$SSHD_TUNNEL_IP"
else
	SERVER_IPS="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | tr '\n' ' ')"
fi
[ -n "$SERVER_IPS" ] || SERVER_IPS='<server-ip>'
PRIMARY_IP="${SERVER_IPS%% *}"
PRIMARY_IP="${PRIMARY_IP% }"

# ---------------------------------------------------------------- HTTP bootstrap
BOOTSTRAP_URL=''
SERVED_ARCHES=''
if [ "$HTTP_ENABLED" -eq 1 ] && [ "$SERVE" -eq 1 ]; then
	TOKEN="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
	TOKEN_DIR="$WEB_ROOT/t/$TOKEN"
	rm -rf "$WEB_ROOT/t"
	mkdir -p "$TOKEN_DIR/bin"

	# One patched copy per architecture. Copied, never hard-linked: the copy
	# is what gets patched, and a hard link would write the credentials into
	# the pristine binaries in $DBT_BIN_DIR.
	for b in "$DBT_BIN_DIR"/dropbearmulti-*; do
		[ -f "$b" ] || continue
		name="$(basename "$b")"
		cp "$b" "$TOKEN_DIR/bin/$name"
		for slot in id hk ak; do
			case "$slot" in
				id) payload="$ID_KEY" ;;
				hk) payload="$HK_KEY" ;;
				ak) payload="$DEVICE_KEY.pub" ;;
			esac
			/usr/local/bin/patch-cred "$TOKEN_DIR/bin/$name" "$slot" "$payload" >/dev/null \
				|| die "cannot patch the $slot slot of $name"
		done
		chmod 644 "$TOKEN_DIR/bin/$name"
		SERVED_ARCHES="$SERVED_ARCHES${name#dropbearmulti-} "
	done
	[ -n "$SERVED_ARCHES" ] || die "no dropbearmulti-* binaries in $DBT_BIN_DIR"

	{
		printf '#!/bin/sh\n'
		printf '# %s --serve bootstrap, generated %s\n' "$PROG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'SRV=%s\n'       "$(shquote "$PRIMARY_IP")"
		printf 'SSH_PORT=%s\n'  "$(shquote "$PORT")"
		printf 'HTTP_PORT=%s\n' "$(shquote "$HTTP_PORT")"
		printf 'TOKEN=%s\n'     "$(shquote "$TOKEN")"
		printf '[ -n "${RPORT:-}" ] || RPORT=%s\n' "$(shquote "$EXPOSE_RPORT")"
		printf '[ -n "${LHOST:-}" ] || LHOST=%s\n' "$(shquote "$EXPOSE_LHOST")"
		printf '[ -n "${LPORT:-}" ] || LPORT=%s\n' "$(shquote "$EXPOSE_LPORT")"
		printf '\n'
		cat "$SERVE_BODY"
	} > "$TOKEN_DIR/s"
	chmod 644 "$TOKEN_DIR/s"

	BOOTSTRAP_URL="http://$PRIMARY_IP:$HTTP_PORT/t/$TOKEN/s"

	busybox-extras httpd -f -p "0.0.0.0:$HTTP_PORT" -h "$WEB_ROOT" &
	HTTPD_PID=$!
	log "bootstrap HTTP server listening on 0.0.0.0:$HTTP_PORT (pid $HTTPD_PID)"
elif [ "$HTTP_ENABLED" -eq 1 ]; then
	[ -f "$BOOTSTRAP_BODY" ] || die "missing $BOOTSTRAP_BODY"
	TOKEN="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
	TOKEN_DIR="$WEB_ROOT/t/$TOKEN"
	rm -rf "$WEB_ROOT/t"
	mkdir -p "$TOKEN_DIR"

	if [ "$AUTH_MODE" = 'key' ]; then
		cp "$CLIENT_KEY" "$TOKEN_DIR/id"
		# Pre-converted to Dropbear's own format, so a 2014 device needs only
		# dbclient — no local dropbearconvert, no OpenSSH key parsing.
		dropbearconvert openssh dropbear "$CLIENT_KEY" "$TOKEN_DIR/id.db" >/dev/null 2>&1 \
			|| die 'dropbearconvert failed to convert the generated key'
		chmod 644 "$TOKEN_DIR/id" "$TOKEN_DIR/id.db"
	fi

	# Header of quoted assignments, then the fixed body. RPORT/LHOST/LPORT are
	# only defaults so the device can override them:
	#   wget -O- <url> | RPORT=5900 sh
	{
		printf '#!/bin/sh\n'
		printf '# %s bootstrap, generated %s\n' "$PROG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'SRV=%s\n'       "$(shquote "$PRIMARY_IP")"
		printf 'SSH_PORT=%s\n'  "$(shquote "$PORT")"
		printf 'HTTP_PORT=%s\n' "$(shquote "$HTTP_PORT")"
		printf 'TOKEN=%s\n'     "$(shquote "$TOKEN")"
		printf 'MODE=%s\n'      "$(shquote "$AUTH_MODE")"
		printf 'PASSWORD=%s\n'  "$(shquote "$PASSWORD")"
		printf '[ -n "${RPORT:-}" ] || RPORT=%s\n' "$(shquote "$EXPOSE_RPORT")"
		printf '[ -n "${LHOST:-}" ] || LHOST=%s\n' "$(shquote "$EXPOSE_LHOST")"
		printf '[ -n "${LPORT:-}" ] || LPORT=%s\n' "$(shquote "$EXPOSE_LPORT")"
		printf '\n'
		cat "$BOOTSTRAP_BODY"
	} > "$TOKEN_DIR/b"
	chmod 644 "$TOKEN_DIR/b"

	BOOTSTRAP_URL="http://$PRIMARY_IP:$HTTP_PORT/t/$TOKEN/b"

	# busybox httpd serves static files only; without an index file a request
	# for a directory is a 404, so the token is the only way in.
	busybox-extras httpd -f -p "0.0.0.0:$HTTP_PORT" -h "$WEB_ROOT" &
	HTTPD_PID=$!
	log "bootstrap HTTP server listening on 0.0.0.0:$HTTP_PORT (pid $HTTPD_PID)"
fi

# ----------------------------------------------------------------------- banner
if [ "$SERVE" -eq 1 ]; then
	# Where the operator will find the key on the host. The wrapper passes the
	# rootfs path in; without it (someone chrooting by hand) the chroot path
	# is all there is to show.
	DEVICE_KEY_HOST="${SSHD_TUNNEL_ROOTFS:-<rootfs>}$DEVICE_KEY"
	cat <<EOF

  $PROG — reverse-tunnel-only SSH server, --serve
  ------------------------------------------------------------------
  sshd port        : $PORT (all interfaces)
  addresses        : $SERVER_IPS
  auth mode        : key only; the identity is embedded in the device binary
  account          : tcp (no shell, -R forwards only)
  PermitListen     : $PERMIT_LISTEN
  host key SHA256  : $HOST_FP
  binaries served  : $SERVED_ARCHES

  The device gets its own SSH server (Dropbear, key only), bound to
  $EXPOSE_LHOST:$EXPOSE_LPORT on the device and exposed here as port $EXPOSE_RPORT.
  Its host key SHA256: $DEVICE_HOST_FP

  One-liner for the device (needs only a shell and wget or curl):
    wget -O- $BOOTSTRAP_URL | sh

  Or with curl:
    curl -fsSL $BOOTSTRAP_URL | sh

  It detects the architecture, pulls the matching static Dropbear with the
  credentials already inside, checks it runs on that CPU, starts the SSH
  server and opens the tunnel. Override the ports on the device side:
    wget -O- $BOOTSTRAP_URL | RPORT=10023 LPORT=2223 sh

  Once it connects, log into the device from this host (the account is one
  that exists on the device — root on most routers):
    ssh -i $DEVICE_KEY_HOST -p $EXPOSE_RPORT root@127.0.0.1

  The same key, to use from anywhere this host is reachable
  (ssh -i key -p $EXPOSE_RPORT root@$PRIMARY_IP) — regenerated on every start:

EOF
	cat "$DEVICE_KEY"
	cat <<EOF

  NOTE: that URL serves binaries with all three credentials inside over
  plain HTTP, to anyone who knows the token, for as long as this process
  runs. Everything is replaced on restart; the device then needs the new
  one-liner.

  Press Ctrl-C to stop.
  ------------------------------------------------------------------

EOF
else
cat <<EOF

  $PROG — reverse-tunnel-only SSH server
  ------------------------------------------------------------------
  sshd port        : $PORT (all interfaces)
  addresses        : $SERVER_IPS
  auth mode        : $AUTH_MODE only
  account          : tcp (no shell, -R forwards only)
  PermitListen     : $PERMIT_LISTEN
  host key SHA256  : $HOST_FP
  host key MD5     : $HOST_FP_MD5
EOF
fi

if [ "$SERVE" -eq 1 ]; then
	:
elif [ "$AUTH_MODE" = 'password' ]; then
	cat <<EOF
  password         : $PASSWORD

  Dropbear client (2014 and newer):
    DROPBEAR_PASSWORD=$(shquote "$PASSWORD") dbclient -y -K 30 -I 0 -N \\
      -R $EXPOSE_RPORT:$EXPOSE_LHOST:$EXPOSE_LPORT -p $PORT tcp@$PRIMARY_IP
EOF
else
	cat <<EOF

  Client private key ($KEY_TYPE, PEM) — regenerated on every start:

EOF
	cat "$CLIENT_KEY"
	cat <<EOF

  Dropbear client (2014 and newer), after saving the key as id_key:
    dropbearconvert openssh dropbear id_key id.db
    dbclient -y -K 30 -I 0 -N -i id.db \\
      -R $EXPOSE_RPORT:$EXPOSE_LHOST:$EXPOSE_LPORT -p $PORT tcp@$PRIMARY_IP
EOF
fi

if [ "$SERVE" -eq 1 ]; then
	:
elif [ -n "$BOOTSTRAP_URL" ]; then
	cat <<EOF

  One-liner for the device (fetches credentials and reconnects on drop):
    wget -O- $BOOTSTRAP_URL | sh

  Override the mapping on the device side if needed:
    wget -O- $BOOTSTRAP_URL | RPORT=5900 LPORT=5900 sh
EOF
	if [ "$AUTH_MODE" = 'key' ]; then
		cat <<EOF

  NOTE: that URL serves the private key over plain HTTP to anyone who knows
  the token, for as long as this process runs. The key is replaced on restart.
EOF
	fi
fi

[ "$SERVE" -eq 1 ] || cat <<EOF

  Once the client is connected, the tunnel appears on this server as
  0.0.0.0:$EXPOSE_RPORT. Press Ctrl-C to stop.
  ------------------------------------------------------------------

EOF

# ------------------------------------------------------------------------- sshd
# Run in the background and wait, so the cleanup trap still fires: with `exec`
# the httpd child and the published token would survive this process.
/usr/sbin/sshd -D -e -f "$CONFIG" &
SSHD_PID=$!
wait "$SSHD_PID"

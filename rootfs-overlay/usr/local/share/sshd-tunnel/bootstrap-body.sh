# Body of the bootstrap script served over HTTP. /run.sh prepends a header of
# shell-quoted variable assignments and serves the concatenation; this file
# contains no placeholders, so no value ever needs sed-escaping.
#
# Expected variables: SRV SSH_PORT HTTP_PORT TOKEN MODE PASSWORD RPORT LHOST LPORT
# Overridable from the environment: RPORT LHOST LPORT LOOP
#
# Target: busybox ash on a device from around 2014. Nothing here may rely on
# bash, on GNU coreutils flags, or on TLS.

set -u

PROG='sshd-tunnel'
say() { printf '%s: %s\n' "$PROG" "$*" >&2; }

have() {
	command -v "$1" >/dev/null 2>&1 && return 0
	which "$1" >/dev/null 2>&1
}

WORKDIR="${TMPDIR:-/tmp}/sshd-tunnel.$$"
mkdir -p "$WORKDIR" || { say "cannot create $WORKDIR"; exit 1; }
trap 'rm -rf "$WORKDIR"' EXIT INT TERM HUP

fetch() {
	if have wget; then
		wget -q -O "$2" "$1" && return 0
	fi
	if have curl; then
		curl -fsS -o "$2" "$1" && return 0
	fi
	return 1
}

# ------------------------------------------------------------- pick an SSH client
if have dbclient; then
	CLIENT='dbclient'
elif have ssh; then
	CLIENT='ssh'
else
	say 'neither dbclient nor ssh is available on this device'
	exit 1
fi
say "using $CLIENT"

# --------------------------------------------------------------- fetch the key
KEY=''
if [ "$MODE" = 'key' ]; then
	if [ "$CLIENT" = 'dbclient' ]; then
		# Already in Dropbear's native format, so even builds without a local
		# dropbearconvert can use it.
		KEY="$WORKDIR/id.db"
		KEY_NAME='id.db'
	else
		KEY="$WORKDIR/id"
		KEY_NAME='id'
	fi
	if ! fetch "http://$SRV:$HTTP_PORT/t/$TOKEN/$KEY_NAME" "$KEY"; then
		say "cannot fetch http://$SRV:$HTTP_PORT/t/$TOKEN/$KEY_NAME"
		exit 1
	fi
	chmod 600 "$KEY"
	say 'key retrieved'
fi

# ------------------------------------------------------------------- connect
say "exposing $LHOST:$LPORT of this device as $SRV:$RPORT"

connect_dbclient() {
	if [ "$MODE" = 'key' ]; then
		dbclient -y -K 30 -I 0 -N -i "$KEY" \
			-R "$RPORT:$LHOST:$LPORT" -p "$SSH_PORT" "tcp@$SRV" </dev/null
	else
		DROPBEAR_PASSWORD="$PASSWORD" dbclient -y -K 30 -I 0 -N \
			-R "$RPORT:$LHOST:$LPORT" -p "$SSH_PORT" "tcp@$SRV" </dev/null
	fi
}

connect_ssh() {
	set -- -N -T \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o ServerAliveInterval=30 \
		-o ExitOnForwardFailure=yes \
		-R "$RPORT:$LHOST:$LPORT" -p "$SSH_PORT" "tcp@$SRV"
	if [ "$MODE" = 'key' ]; then
		ssh -i "$KEY" -o IdentitiesOnly=yes "$@" </dev/null
	elif have sshpass; then
		sshpass -p "$PASSWORD" ssh -o PubkeyAuthentication=no "$@" </dev/null
	else
		say 'password mode with the OpenSSH client needs sshpass, or a terminal'
		say "the password is: $PASSWORD"
		ssh -o PubkeyAuthentication=no "$@"
	fi
}

DELAY=5
while :; do
	if [ "$CLIENT" = 'dbclient' ]; then
		connect_dbclient || true
	else
		connect_ssh || true
	fi

	[ "${LOOP:-1}" = '1' ] || break

	say "disconnected, retrying in ${DELAY}s"
	sleep "$DELAY"
	# Back off to a minute so a permanently rejected client does not hammer
	# the server, but stay responsive for ordinary link flaps.
	[ "$DELAY" -lt 60 ] && DELAY=$((DELAY * 2)) || DELAY=60
done

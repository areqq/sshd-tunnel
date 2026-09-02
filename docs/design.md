# sshd-tunel — design

Status: implemented. Written before the code, updated with what the
implementation actually found out.

## Problem

A device from around 2014 — an embedded box running Dropbear 2014.x behind NAT —
needs to expose a local port on a reachable server. The device can only dial
out, and its SSH client predates every algorithm modern OpenSSH prefers.

The server side must therefore:

1. accept an inbound SSH connection from that ancient client;
2. accept a reverse forward (`-R`) and publish it on all of the server's
   interfaces;
3. grant nothing else — no shell, no local forwarding, no file transfer;
4. install and run without touching the host system, from a single command;
5. offer a way to provision the device that does not involve manually copying
   a key onto it.

## Shape

Three layers, each independently testable:

| Layer | Where | Responsibility |
|---|---|---|
| `build/build-rootfs.sh` | build time, Alpine container as root | bootstrap the rootfs with `apk.static`, apply the overlay, verify, package |
| `run` | runtime, on the host as root | mount `/proc` and the needed `/dev` nodes, `chroot`, unmount on exit |
| `rootfs-overlay/run.sh` | runtime, inside the chroot | keys, config rendering, credentials, bootstrap server, `sshd` |

The chroot's entrypoint is `/run.sh`, not `/run`: `/run` must stay a directory
because OpenSSH keeps its pid file there. The host wrapper is named `run`, so
the user-facing command is unaffected.

## Decisions

### Alpine latest, not a pinned legacy branch

The concern was that OpenSSH 10 had removed the algorithms Dropbear 2014 needs.
Probing 10.3p1 showed otherwise: `diffie-hellman-group1-sha1`,
`group14-sha1`, `group-exchange-sha1`, `ssh-rsa`, `hmac-sha1`, `hmac-md5`,
`3des-cbc` and the CBC AES modes are all still present, merely disabled by
default. Only `ssh-dss` is gone, and Dropbear 2014.63 supports `ssh-rsa`, so
nothing is lost. Pinning an old Alpine branch would have traded security
patches for nothing.

Legacy algorithms are enabled with `+`, which appends to the modern defaults
rather than replacing them: a current client still negotiates current crypto.

### The legacy gate is a parse check

OpenSSH validates algorithm *names* while parsing `sshd_config`, before it
loads host keys. A config naming an algorithm the binary no longer supports is
rejected outright (`Bad SSH2 KexAlgorithms`, `Bad key types`). So rendering the
real template and handing it to `sshd -t` proves every legacy algorithm still
exists in this build. `build/verify-rootfs.sh` does exactly that and fails the
build otherwise, then also asserts each name reached the *effective* list that
`sshd -T` reports.

This is a build-time gate rather than a runtime hope: a future Alpine that
drops `hmac-sha1` stops the release instead of shipping a server the old client
cannot talk to.

### Two authentication modes, never both

A password on the command line selects password-only; its absence selects
key-only. The unused method is switched off, not deprioritised, and the
artefacts of the other mode are actively removed — `authorized_keys` is
truncated in password mode.

The **host** key is persistent (generated on first start, kept in the chroot,
carried across upgrades by `install.sh`) because a client that remembers host
keys would otherwise report a changed fingerprint after every restart. The
**client** key is regenerated on every start, which was the explicit
requirement.

### The account is not "locked"

The obvious way to forbid password login in key mode is `!` in `/etc/shadow`.
It does not work: OpenSSH treats a shadow entry beginning with `!` or `*` as a
locked *account* and refuses it before authentication method selection — key
authentication included. Discovered by the test suite, not by reading.

Instead the account gets a hash of a random string that is discarded
immediately. Passwords are unmatchable in practice, and password
authentication is off anyway, but the account stays usable.

### Client key types: RSA and ECDSA only

`--key-type` accepts `rsa2048` (the default), `rsa3072`, `rsa4096`, `ecdsa256`,
`ecdsa384` and `ecdsa521`. The list is exactly what Dropbear 2014.63 can use,
established by probing its own `dropbearkey` (`rsa`, `dss`, `ecdsa`) and then
confirming each candidate through the full chain rather than trusting the help
text.

`ecdsa256` is the interesting one: 140 bytes in Dropbear's format against
RSA-2048's 1189, and far cheaper to verify on 2014-era hardware. The default
stays RSA because ECDSA arrived in Dropbear 2013.56, so a device older than
that still needs RSA.

Two omissions are deliberate and produce an error, not a fallback:

- **`ed25519`** — absent from Dropbear until 2020.79. It also has no PEM
  encoding, and `ssh-keygen -m PEM -t ed25519` simply fails, so the manual
  `dropbearconvert` path on a 2014 device could not work either.
- **`ssh-dss`** — Dropbear supports it, but OpenSSH 10 dropped it server-side,
  so the server can never accept such a key. Supporting it would mean pinning
  an older OpenSSH, which the Alpine-latest decision above already rejected.

The **host** key stays RSA: it is the only algorithm Dropbear 2014 and OpenSSH
10 still share, now that `ssh-dss` is gone from one side and everything modern
is missing from the other.

### `PermitListen *:*`, not `0.0.0.0:*`

`PermitListen` matches the bind address the **client** requested, not the
address the listener ends up on. Dropbear sends `localhost`, so a policy of
`0.0.0.0:*` refuses every forward the old client asks for — which the tests
caught as `the request was denied` in the server log. `*:*` matches any
requested address.

`PermitListen` also accepts no port *ranges*, so the original intention of
"any unprivileged port" is not expressible. Narrowing is therefore done by
listing bare port numbers via `--listen`, which match any bind address.

### Device nodes are bind-mounted, not shipped

A tarball containing real device nodes cannot be unpacked without `mknod`
privileges. The rootfs ships empty placeholder files, and the host wrapper
bind-mounts `/dev/null`, `zero`, `full`, `random`, `urandom` and `tty` onto
them. `/proc` is mounted normally.

The wrapper *adopts* mounts it finds already in place instead of skipping them,
so a mount leaked by an earlier run is still cleaned up. A leaked bind mount
otherwise makes the rootfs impossible to delete and silently breaks the next
build — this happened during development, so `tests/test-tunnel-key.sh` now
asserts the wrapper leaves nothing mounted.

### Ownership is repaired at runtime

`sshd` enforces `StrictModes` on `/var/empty` and on the path to
`authorized_keys`, and refuses to start if they are owned by the wrong user.
Unpacking the release as a normal user gives everything that user's uid, so
`/run.sh` repairs ownership at startup rather than requiring `sudo tar`.

### HTTP bootstrap: BusyBox httpd, static files, token in the URL

`busybox-extras` provides an `httpd` applet, which serves the generated script
and the key as static files under `/srv/www/t/<32-hex-token>/`. No CGI is
needed because the endpoint has neither an expiry nor a download limit, which
was a deliberate choice: provisioning several devices from one URL was worth
more than one-shot semantics.

The chroot also carries `dropbearconvert`, so the key is published *already in
Dropbear's native format* — a 2014 device needs nothing but `dbclient` and
`wget`.

**Accepted risk:** in key mode this serves a private key over plain HTTP to
anyone who learns the token, for as long as the server runs. Mitigations are
that the key is replaced on every restart, that `--no-http` disables the
mechanism, and that password mode publishes no key at all. Documented
prominently in the README rather than hidden.

### Values are shell-quoted, not substituted

The generated bootstrap script embeds a password. Rendering it with `sed` breaks
on quotes, backslashes and the `sed` delimiter, so `/run.sh` writes a header of
properly single-quoted assignments and concatenates a fixed body that contains
no placeholders. `tests/test-tunnel-password.sh` uses `p'a"s$s\w0rd!` as the
password to keep that honest.

### `ForceCommand` sleeps rather than exits

`/bin/false` as a forced command would close the session channel immediately,
and some clients tear down the whole connection — and with it the tunnel — when
that happens. `tunnel-only` prints a notice and sleeps instead.

## Testing

The suite runs against the unpacked release tarball, not the build staging
directory, so it exercises what users actually get. It needs root because of
the bind mounts, which is also why the tests run directly on the CI runner
rather than in a container.

Its centrepiece is a genuine **Dropbear 2014.63 client compiled from source**,
pinned by SHA-256. Two adjustments are needed to build 2014-era C today:
`-std=gnu89`, because C23 (GCC 15's default) reads `int (*f)()` as a prototype
taking no arguments and breaks `atomicio.c`; and `linux-headers` on Alpine.

| Test | Asserts |
|---|---|
| `test-tunnel-key.sh` | the printed key converts with the 2014 `dropbearconvert`, the forward comes up, bytes traverse it, the listener is on `0.0.0.0`, and the wrapper unmounts on exit |
| `test-tunnel-password.sh` | the same over `DROPBEAR_PASSWORD` with an awkward password; keys are refused in password mode |
| `test-restrictions.sh` | no shell, `-L` carries nothing, `PermitListen` narrowing is enforced, other accounts and passwords are refused, and the permitted forward still works |
| `test-key-types.sh` | every `--key-type` value converts with the 2014 tool, authenticates and carries data; unsupported types are refused rather than silently downgraded |
| `test-bootstrap.sh` | the token is required, the served script is valid POSIX shell, running it establishes the tunnel in both modes |

Data actually moving through the forward is the assertion in every tunnel test —
an established listener proves less than a byte arriving.

## CI

`build` runs the Alpine build via Docker on an `ubuntu-latest` runner. The job
cannot use `container: alpine` because `actions/checkout` ships a glibc-linked
Node runtime that will not execute on musl.

`test` downloads the artefact, verifies its checksum, unpacks it as root and
runs the suite; the Dropbear client is cached on its pinned version. `release`
publishes the tarball, its checksum and `install.sh` for `v*` tags.

## Limitations

- x86_64 releases only; `ARCH` builds others but nothing publishes them
- Linux only, root required for `chroot` and bind mounts
- the bootstrap endpoint is plain HTTP with a bearer token and no expiry
- forwarded ports are exposed on all interfaces by design

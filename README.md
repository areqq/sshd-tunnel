# sshd-tunnel

A self-contained Alpine chroot (about 6 MB packed) holding an OpenSSH server
whose only purpose is to accept a **reverse TCP forward** from an old device
and publish it on every interface of the host — plus an OpenVPN mode for when
one forwarded port is not enough (see [VPN mode](#vpn-mode)).

It talks to a **Dropbear client from 2014** — SHA-1 era key exchange, `ssh-rsa`
host keys, `hmac-sha1`, CBC ciphers — while giving that client nothing except
the forward: no shell, no local forwarding, no SFTP, no agent, no PTY.

Releases are built by GitHub Actions and every legacy algorithm is verified
against a Dropbear 2014.63 client compiled from source in CI.

## Install and run

```sh
curl -fsSL https://raw.githubusercontent.com/areqq/sshd-tunnel/main/install.sh | sh -s -- 2222
```

That downloads the latest release, verifies its SHA-256, unpacks it into
`./sshd-tunnel/`, and starts the server on port 2222 with **key-only**
authentication — printing a freshly generated private key you hand to the
device.

With a password instead:

```sh
curl -fsSL https://raw.githubusercontent.com/areqq/sshd-tunnel/main/install.sh | sh -s -- 2222 'my-password'
```

Install without starting, then run it yourself:

```sh
curl -fsSL https://raw.githubusercontent.com/areqq/sshd-tunnel/main/install.sh | sh
sudo ./sshd-tunnel/run 2222
```

Root is required — `chroot` and the bind mounts need it. The wrapper re-execs
itself under `sudo` when it is not already root.

Only `wget`? Same thing:

```sh
wget -qO- https://raw.githubusercontent.com/areqq/sshd-tunnel/main/install.sh | sh -s -- 2222
```

## What it does

```
[device behind NAT, Dropbear 2014]
      dbclient -N -R 10022:127.0.0.1:22 tcp@server -p 2222
            |
            |  outbound TCP to server:2222
            v
[server]  sshd inside the chroot, listening on 0.0.0.0:2222
          -> opens a listener on 0.0.0.0:10022
          -> traffic to server:10022 comes out on the device's 127.0.0.1:22
```

The device dials out, so nothing needs to be forwarded to it. On the server,
the tunnelled port is reachable from anywhere the host is reachable
(`GatewayPorts yes`).

## Authentication

Exactly one method is active, chosen by whether you pass a password:

| | `run 2222` | `run 2222 secret` |
|---|---|---|
| password auth | **off** | on |
| public-key auth | on | **off** |
| client key | RSA-2048 generated and printed **at every start** | not generated |
| account | `tcp` | `tcp` |

The SSH **host** key is generated once, on first start, and kept in the chroot,
so a client that remembers host keys will not see a changed fingerprint after a
restart. `install.sh` carries it across upgrades too.

The client key is *not* persistent: every start prints a new one and invalidates
the previous one. Copy it while it is on screen.

### Key types

```sh
sudo ./sshd-tunnel/run 2222 --key-type ecdsa256
```

| `--key-type` | Dropbear 2014.63 | Notes |
|---|---|---|
| `rsa2048` (default) | yes | the safe choice; works with every Dropbear that speaks SSH2 |
| `rsa3072`, `rsa4096` | yes | slower handshake on 2014-era CPUs |
| `ecdsa256` | yes | 140-byte key against RSA-2048's 1189, and much cheaper to verify — worth it on weak hardware |
| `ecdsa384`, `ecdsa521` | yes | as above with larger curves |

Every one of those is asserted end-to-end in `tests/test-key-types.sh`: generated
on the server, converted by the **2014** `dropbearconvert`, authenticated, and
carrying real bytes through the forward.

Two types are deliberately unavailable, and asking for them is an error rather
than a silent fallback:

- **`ed25519`** — Dropbear gained it in 2020.79, and it has no PEM
  representation a 2014 `dropbearconvert` could read.
- **`ssh-dss`** — Dropbear supports it, but OpenSSH 10 removed it from the
  server side, so the server could never accept it.

The key type applies to the **client** key only; the host key stays RSA, which
is the one type Dropbear 2014 and OpenSSH 10 still have in common.

In password mode no client key is generated, and `--key-type` is ignored with a
notice.

Passing the password as an argument makes it visible in the host's process
list; `SSHD_TUNNEL_PASSWORD` avoids that:

```sh
SSHD_TUNNEL_PASSWORD='my-password' sudo -E ./sshd-tunnel/run 2222
```

## Bootstrapping the device over HTTP

Getting a key onto a 2014 device by hand is tedious, so the chroot also runs a
BusyBox HTTP server that hands out a ready-made connect script. The startup
banner prints the command:

```sh
wget -O- http://10.0.0.5:2223/t/9f3a…c1/b | sh
```

That script picks `dbclient` or `ssh`, fetches the key (already converted to
Dropbear's own format, so the device needs no `dropbearconvert`), opens the
reverse forward, and reconnects with backoff if the link drops. Override the
mapping from the device side:

```sh
wget -O- http://10.0.0.5:2223/t/9f3a…c1/b | RPORT=5900 LPORT=5900 sh
```

The HTTP port defaults to the sshd port + 1, and the 32-hex-character token is
the only thing protecting the URL — anything without it gets a 404.

> **Security note.** In key mode this URL serves the private key over plain
> HTTP to anyone who knows the token, with no expiry and no download limit, for
> as long as the server runs. That is a deliberate trade-off for one-shot
> provisioning of devices that have no TLS. Restarting the server replaces the
> key and the token. Use `--no-http` to switch the whole mechanism off, or a
> password instead of a key so no private key is ever published.

## Options

```
run <port> [password] [options]

  --no-http             do not serve the bootstrap script
  --http <port>         bootstrap HTTP port           (default: <port> + 1)
  --listen <patterns>   PermitListen value            (default: *:*)
  --expose <r:h:p>      mapping baked into the
                        bootstrap script              (default: 10022:127.0.0.1:22)
  --key-type <type>     client key to generate        (default: rsa2048)
  --check-config        render and validate the sshd config, then exit
```

`--listen` narrows which ports the client may open. Two OpenSSH details shape
the default here: `PermitListen` accepts no port *ranges* (only exact ports and
`*`), and it matches against the bind address the **client** asked for — which
Dropbear sends as `localhost`, not `0.0.0.0`. So the default is `*:*`, and
narrowing is done by listing bare port numbers, which match any bind address:

```sh
sudo ./sshd-tunnel/run 2222 --listen '10022 5900'
```

## Connecting by hand

Dropbear 2014 and newer, key mode:

```sh
dropbearconvert openssh dropbear id_rsa id.db
dbclient -y -K 30 -I 0 -N -i id.db -R 10022:127.0.0.1:22 -p 2222 tcp@server
```

Dropbear, password mode:

```sh
DROPBEAR_PASSWORD='my-password' dbclient -y -K 30 -I 0 -N \
  -R 10022:127.0.0.1:22 -p 2222 tcp@server
```

A current OpenSSH client:

```sh
ssh -i id_rsa -N -T -o ExitOnForwardFailure=yes \
  -R 10022:127.0.0.1:22 -p 2222 tcp@server
```

## What the account cannot do

`sshd_config` switches these off, and `tests/test-restrictions.sh` asserts each
one against the real 2014 client:

- **no shell** — `ForceCommand` prints a notice and sleeps, so a session
  channel neither runs commands nor kills the tunnel
- **no `-L` / `-D`** — `AllowTcpForwarding remote`, `PermitOpen none`
- **no SFTP**, no PTY, no X11, no agent forwarding, no Unix-socket forwarding
- **no other account** — `AllowUsers tcp`, `PermitRootLogin no`
- in key mode the authorized key itself carries `restrict,port-forwarding`, so
  it stays useless for anything else even if the config changed

## VPN mode

The reverse-SSH mode forwards one port. When the device has to be reachable as
a whole — every port, and traffic the server starts — there is a
point-to-point OpenVPN tunnel instead:

```sh
sudo ./run --vpn                    # udp/1194, device becomes 10.9.0.2
sudo ./run --vpn --proto tcp        # for networks that only pass TCP
```

It prints a one-liner of the same shape as the SSH one. On the device:

```sh
wget -O- http://<server>:1195/t/<token>/v | sh
```

That fetches the static key, writes a config into `/tmp`, and connects. The
device needs its own `openvpn` binary — unlike the SSH side, nothing is
shipped for it, and the one-liner says so plainly instead of failing quietly.

**Static key, no PKI.** A fresh `--secret` key per start, point-to-point, no
certificates to manage. It is chosen for reach rather than fashion: the
routers this is aimed at run OpenVPN 2.4 and 2.5, and `--peer-fingerprint`
(the modern no-PKI alternative) needs 2.6 on both ends. OpenVPN 2.7 only
starts such a tunnel with `--allow-deprecated-insecure-static-crypto`, which
the server adds for itself after probing for it; 2.8 is expected to drop the
mode, and this will have to be revisited then.

**The device's firewall is the usual reason it looks dead.** The tunnel can be
fully up — both ends addressed, traffic flowing from the device — while pings
from the server vanish, because OpenWrt drops input on an interface that
belongs to no firewall zone. Test from the device first (`ping 10.9.0.1`); if
that works, the tunnel is fine and only the device's input policy is in the
way. The banner prints the `uci` incantation to open it.

**`/dev/net/tun` must exist on the host.** `./run --vpn` bind-mounts it into
the chroot and refuses to start without it (`modprobe tun`). The SSH mode does
not need it and does not mount it.

## Operational notes

**Repeated failed logins get throttled.** OpenSSH 10 enables
`PerSourcePenalties`, so an address that fails authentication several times is
refused for a growing interval. That is left on deliberately — the server is
meant to be exposed — but it means a device retrying with the wrong key or
password locks itself out for a while rather than failing fast. If a device
cannot connect, check the server output for `srclimit_penalise` before
suspecting the algorithms.

**The client key changes on restart.** Restarting the server invalidates the
key the device is holding. Re-run the bootstrap one-liner, or use password mode
if the device must survive server restarts unattended.

**Stopping the server.** Ctrl-C, or `SIGTERM` to the `run` process. Both let
the wrapper stop `sshd`, remove the published token and unmount `/proc` and the
`/dev` bindings. Killing it with `SIGKILL` leaves those mounts behind; the next
start adopts and cleans them, but `umount` them yourself if you delete the
directory first.

## Legacy algorithms

Added with `+`, so current clients still negotiate modern crypto and only the
old client falls back:

```
KexAlgorithms  +diffie-hellman-group14-sha1, group1-sha1, group-exchange-sha1
HostKeyAlgorithms / PubkeyAcceptedAlgorithms  +ssh-rsa
Ciphers        +aes128-cbc, aes192-cbc, aes256-cbc, 3des-cbc
MACs           +hmac-sha1, hmac-sha1-96, hmac-md5, hmac-md5-96
```

`ssh-dss` (DSA) is gone from OpenSSH 10 and cannot be re-enabled; Dropbear
2014.63 supports `ssh-rsa`, so it is not needed.

`build/verify-rootfs.sh` fails the build if any of the algorithms above
disappears from a future OpenSSH — the config is rejected at parse time, so it
cannot ship silently broken.

## Building it yourself

CI does this on every push, but locally:

```sh
build/build.sh          # podman or docker; writes dist/sshd-tunnel-x86_64.tgz
```

Or on an Alpine host, as root:

```sh
ARCH=x86_64 build/build-rootfs.sh
```

## Testing

```sh
sudo tests/run-all.sh
```

Compiles Dropbear 2014.63 from source (pinned by SHA-256) and runs the tunnel,
key-type, password, restriction and bootstrap suites against the built chroot.
Requires `python3` and a C toolchain; the chroot's bind mounts mean the tests
need root.

## Layout

```
build/build.sh              run the build in a container
build/build-rootfs.sh       bootstrap the rootfs with apk.static, package it
build/verify-rootfs.sh      build-time gate: legacy algorithms and restrictions
build/packages.txt          what goes into the chroot
rootfs-overlay/run.sh       entrypoint inside the chroot
rootfs-overlay/etc/ssh/sshd_config.tmpl
rootfs-overlay/usr/local/bin/tunnel-only
rootfs-overlay/usr/local/share/sshd-tunnel/bootstrap-body.sh
run                         host wrapper: mounts, chroot, cleanup
install.sh                  download a release and start it
tests/                      the suite, including the Dropbear 2014 builder
```

`/run.sh` rather than `/run` inside the chroot, because `/run` has to stay a
directory — OpenSSH keeps its pid file there. The host-side wrapper is `run`,
so the command you type is still `./run 2222`.

## Limitations

- x86_64 only in the published releases (`ARCH` can build others)
- Linux only; needs root for `chroot` and bind mounts
- the bootstrap HTTP endpoint is plain HTTP with a bearer-token URL and no
  expiry — see the security note above
- the tunnelled port is exposed on all interfaces by design; firewall the
  server if that is not what you want

## License

MIT — see [LICENSE](LICENSE).

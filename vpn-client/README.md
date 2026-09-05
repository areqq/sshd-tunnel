# dsvpn — static multi-arch VPN client that changes nothing on the device

A fully static [DSVPN](https://github.com/jedisct1/dsvpn) binary, 95–143 kB
depending on architecture, for the seven targets this project cares about:
`x86_64 i686 armv7 armv5 aarch64 mips mipsel`.

It exists because of a gap the OpenVPN mode cannot close. That mode needs an
`openvpn` binary already on the device, and plenty of these boxes have none,
no package manager to install one, and no route to the internet anyway. DSVPN
is ~1500 lines of C with its own Xoodoo-based crypto and no dependencies, so
it cross-compiles into something small enough to hand over from the server
along with the key.

The server does exactly that: `./run --dsvpn` embeds all seven binaries in the
chroot and serves the right one over the same token-scoped HTTP bootstrap the
other modes use. So there is no separate install step on the device, and no
`install.sh` here to match `client/install.sh` — the one-liner the server
prints does the whole job.

## Build

```sh
vpn-client/build.sh mips
```

Fetches a Bootlin musl toolchain (shared with `client/` — one download serves
both) and the DSVPN source on demand, applies the patch below, and writes
`out/dsvpn-mips.tgz` plus its SHA-256.

```sh
for a in x86_64 i686 armv7 armv5 aarch64 mips mipsel; do vpn-client/build.sh $a; done
```

Environment: `DSVPN_REF` (default `master`), `TC_VER` (default `2025.08-1`),
`OUT_DIR`.

## The patch

`patches/no-system-changes.patch` is the reason this is not just a stock
build. Upstream DSVPN is built for "route all my traffic through the VPN", and
on connect it:

- sets `net.ipv4.ip_forward` and `tcp_congestion_control=bbr`,
- installs `iptables` rules in the raw, nat and filter tables,
- moves the default route into policy routing table 42069, with matching
  IPv6 rules and blackholes.

That is the right default for its own use case and the wrong one here. This
project wants the device *reachable*, not its traffic *redirected* — the same
contract as the reverse-SSH and OpenVPN modes.

It is also fatal on these targets rather than merely unwanted: dsvpn aborts on
the first of those commands that fails, and every one of them can fail here.
The server runs in a chroot with no iptables at all. `sysctl ...=bbr` wants a
kernel ≥ 4.9 with the module; one router in the test set runs 4.1. The raw
table's `-m addrtype` match is absent from plenty of minimal OpenWrt and
ASUSWRT builds. `ip -6 addr add` fails outright where IPv6 is disabled.

What remains is the irreducible minimum for a point-to-point link:

```
ip link set dev $IF_NAME up
ip addr add $LOCAL_TUN_IP peer $REMOTE_TUN_IP dev $IF_NAME
```

Nothing else on either machine is touched, so there is nothing to undo on exit
either — killing the process removes its tun device and that is all. The patch
also drops upstream's refusal to start when the default gateway or external
interface cannot be detected: with those commands gone, neither value is read
any more on Linux, and detection genuinely does fail in a chroot or on a host
whose only route is the tunnel's. The check is kept for the BSD and macOS
branches, where both are still substituted into real commands.

## Verify

```sh
vpn-client/verify.sh mips out/dsvpn-mips.tgz
sudo vpn-client/verify.sh x86_64 out/dsvpn-x86_64.tgz
```

Four checks, in increasing order of strength:

1. the ELF is static and matches the architecture — including MIPS byte order,
   which the architecture name does not distinguish and which produces a
   binary that fails only on the device;
2. it executes, natively or under `qemu-<arch>-static`. A float-ABI mismatch
   surfaces here as SIGILL, which is a bug this project has shipped once
   already on MIPS;
3. the patch is present in the built binary, checked against the strings that
   would only be there if it were not. Without this, a patch that silently
   stopped matching upstream would ship a client that rewrites a router's
   routing table;
4. with root, on a natively runnable build: a real tunnel between two network
   namespaces, pinged in both directions with 2000-byte payloads, followed by
   an assertion that neither namespace gained a policy routing rule or a new
   default route.

## Trade-offs against the OpenVPN mode

DSVPN is TCP-only, so this is TCP over TCP and it stalls badly on a lossy link
where OpenVPN over UDP would not. It speaks its own protocol with its own
crypto rather than TLS, and it is a far smaller and less scrutinised codebase.
Reach for `--vpn` when the device already has openvpn; reach for `--dsvpn`
when it does not.

## Licence

DSVPN is by Frank Denis, under its own licence — shipped as `DSVPN-LICENSE`
inside each tarball, along with its README.

# dropbear-tunnel — static multi-arch Dropbear with swappable embedded keys

A fully static, multi-call **Dropbear 2026.94** binary (`dropbearmulti` =
`dbclient` + `dropbear` server + `dropbearkey` + `dropbearconvert`, plus
OpenSSH's `sftp` + `sftp-server` merged in as two more applets when built
with `WITH_SFTP=1` — see [SFTP](#sftp-optional-opt-in) below) for the common
embedded architectures, built to be dropped onto a device that then opens a
**reverse tunnel** back to your SSH server.

The distinguishing feature: the credentials are embedded in the binary inside
**fixed-width base64 slots wrapped in magic markers**, so you can swap in a
fresh key on the server — with `sed` or the bundled `patch-cred` — **without
recompiling** and without a toolchain on the device.

## Install on a device

One line on the device itself — it works out which architecture it is,
downloads the matching release into `/tmp`, checks the published SHA-256, and
proves the binary actually runs on that CPU before saying it is done:

```sh
wget -qO- https://raw.githubusercontent.com/areqq/sshd-tunnel/main/client/install.sh | sh
```

```sh
curl -fsSL https://raw.githubusercontent.com/areqq/sshd-tunnel/main/client/install.sh | sh
```

Nothing is written outside `/tmp/dropbear-tunnel`, nothing is started, and no
configuration on the device is touched. Then open the tunnel:

```sh
/tmp/dropbear-tunnel/bootstrap.sh you@your-server -R 22022:127.0.0.1:2222
```

The installer is POSIX `sh` for busybox on genuinely old and minimal devices —
no `mktemp`, no `command` builtin, no `od`/`cmp`/`find -maxdepth`, no bashisms.
`uname -m` reports plain `mips` on both big- and little-endian routers, so the
endianness is read out of an ELF header on the device to pick between the
`mips` and `mipsel` builds. Tested on OpenWrt (mips and mipsel) and
ASUSWRT-Merlin (armv7) hardware.

| variable | default | |
|---|---|---|
| `DBT_DIR` | `/tmp/dropbear-tunnel` | install directory |
| `DBT_ARCH` | autodetected | override the detection |
| `DBT_VERSION` | latest `client-v*` | pin a release tag |
| `DBT_SFTP` | unset | set to `1` for the SFTP-enabled build |
| `DBT_REPO` | `areqq/sshd-tunnel` | source repo |

## Architectures

Built by CI into one `.tgz` each. All static musl, built with `zig cc`, no
libraries, no interpreter.

| arch | slug | typical targets | float |
|---|---|---|---|
| `x86_64` | x86-64 | PCs, x86 appliances | — |
| `i686` | x86-i686 | old 32-bit x86 | — |
| `armv7` | armv7-eabihf | STBs, SBCs (Cortex-A7/A15) | hard |
| `armv5` | armv5-eabi | old routers, IP cameras | soft |
| `aarch64` | aarch64 | armv8 boxes, newer SBCs | — |
| `mips` | mips32 | big-endian routers/NAS | soft |
| `mipsel` | mips32el | little-endian routers (ramips, ath79) | soft |

## The three credential slots

Each slot holds base64 text between unique markers, padded with `.` to a fixed
width so it can be overwritten in place (same length ⇒ the ELF stays valid):

```
@@DBCRED:id:B@@<base64><dots>@@DBCRED:id:E@@
```

| slot | holds | used by |
|---|---|---|
| `id` | client identity private key (Dropbear format) | `dbclient` — the device authenticates to your server with it |
| `hk` | server host key (Dropbear format) | `dropbear` — the device-as-server presents it |
| `ak` | an `authorized_keys` line (text) | `dropbear` — the device-as-server accepts it |

The reader is `volatile`, so the binary always uses whatever bytes are present
in `.rodata` — i.e. whatever you patched — never a compile-time copy. An
unpatched slot (all dots) decodes to nothing and is simply inactive.

## Swapping a key on the server

Generate a key, then patch it into the binary. Two ways, same result:

```sh
# 1) generate a client identity (using the binary's own applet)
./dropbearmulti dropbearkey -t ed25519 -f id_new

# 2a) safe helper — computes padding, guarantees the file size is unchanged
./patch-cred dropbearmulti id id_new

# 2b) or literal sed (what the slot format is designed for). The replacement
#     must be padded to the exact slot width, or the ELF breaks — patch-cred
#     does this for you, so prefer it unless you have a reason not to.
W=$(( $(grep -abo '@@DBCRED:id:E@@' dropbearmulti | head -1 | cut -d: -f1) \
    - $(grep -abo '@@DBCRED:id:B@@' dropbearmulti | head -1 | cut -d: -f1) - 15 ))
B64=$(base64 -w0 id_new)
PAD=$(awk -v n=$((W-${#B64})) 'BEGIN{for(i=0;i<n;i++)printf "."}')
LC_ALL=C sed "s|@@DBCRED:id:B@@[^@]*@@DBCRED:id:E@@|@@DBCRED:id:B@@${B64}${PAD}@@DBCRED:id:E@@|" \
    dropbearmulti > dropbearmulti.new
```

> `sed` on a binary works here **only** because the slot is a marker-delimited,
> newline-free, fixed-width region and the replacement is padded to that exact
> width. `patch-cred` enforces both and verifies the size is unchanged, so it is
> the reliable path; the raw `sed` line is shown because you asked for it.

`hk` and `ak` are patched the same way (`patch-cred dropbearmulti hk hostkey`,
`patch-cred dropbearmulti ak authorized_line`).

## On the device

```sh
# reverse tunnel only: expose the device's port 2222 as your-server:22022
./bootstrap.sh you@your-server -R 22022:127.0.0.1:2222

# also run the embedded server (uses the hk + ak slots) and expose it, so you
# can SSH back into the device through the tunnel:
./bootstrap.sh you@your-server --serve -R 22022:127.0.0.1:2222
```

The identity comes from the `id` slot, so no key file is needed on the device.
`bootstrap.sh` reconnects with backoff if the link drops.

## Crypto

Modern only — see `localoptions.h`. KEX: `curve25519-sha256`, `ecdh-nistp*`,
with `diffie-hellman-group14-sha256` as the sole non-EC fallback. Ciphers:
chacha20-poly1305, AES-GCM, AES-CTR. Signatures: ed25519, ecdsa, rsa-sha2-256.
Deliberately cut: SHA-1, CBC, 3DES, DSS, group1, zlib.

**No post-quantum key exchange.** `mlkem768x25519-sha256` and
`sntrup761x25519-sha512` are both off. They cost 34-70 KB depending on the
architecture (12% of the MIPS binary) and the only thing they protect against
is traffic recorded today being decrypted years from now, which is not a
threat this project is built for. `curve25519-sha256` is what gets negotiated
instead, and OpenSSH has offered it since 6.5. Verified against the real
server this project ships (OpenSSH 10.3p1 in the chroot): the reverse forward
comes up and carries data with `curve25519-sha256` alone.

## Building locally

```sh
client/build.sh x86_64      # fetches toolchain + source, writes client/out/*.tgz
client/build.sh mipsel
```

Needs `curl`, `tar`, `make`, `patch` and `sha256sum`. The cross-compiler is
`zig cc` (zig 0.16.0, pinned by SHA-256): one download serves every target,
and it compiles musl for a target on first use into `client/toolchain/`.
`ZIG_VER` is settable but only 0.16.0 has a pinned checksum in the script.

Two targets need a little help, both linked in only for the architecture that
needs them and both covered by a test the build runs under qemu:

- **armv5** has no atomic instructions, so clang emits calls to the legacy
  `__sync_*` libcalls. zig's compiler-rt does not implement them while zig's
  own C runtime (the allocator behind `malloc`) calls three, so
  `patches/arm-pre-v6-sync.c` supplies those through the kernel's user-helper
  page, the way libgcc does.
- **mips/mipsel** get a correct `pipe()` from `patches/mips-o32-pipe.c`. On
  the o32 ABI `pipe(2)` returns both descriptors in registers rather than
  through the pointer; zig 0.16.0's own `pipe()` ignores that, which leaves
  the server's child process without a working pipe. The failure is quiet —
  a login that succeeds and then produces no output at all.

### Size

Against the previous per-arch Bootlin gcc toolchains, clang's `-Os` is
noticeably tighter on ARM and 32-bit x86 and slightly worse on MIPS:

| arch | now | previously | |
|---|---|---|---|
| `i686` | 393,304 | 497,736 | -21.0% |
| `armv7` | 342,852 | 432,232 | -20.7% |
| `armv5` | 350,340 | 436,324 | -19.7% |
| `x86_64` | 370,584 | 441,752 | -16.1% |
| `aarch64` | 370,504 | 441,648 | -16.1% |
| `mips` | 498,004 | 530,052 | -6.0% |
| `mipsel` | 499,252 | 530,060 | -5.8% |

Stripped `dropbearmulti`, core build; "previously" is the Bootlin gcc build
with post-quantum key exchange enabled. Two changes account for it: clang's
`-Os` is tighter than gcc's on ARM and 32-bit x86 (and about 7% worse on
MIPS), and dropping the two post-quantum key exchanges saves 34-70 KB. The
RSA handshake is about 30% slower with clang on ARM32 (measured on real
hardware, see `TODO.md`); the ed25519 path, which is what the tunnel uses, is
level.

Two further size-reduction attempts on top of the existing `-Os
-ffunction-sections --gc-sections`, both tried under gcc and reverted — see
`TODO.md` for the full story:

- `-flto`: every arch failed to link. Dropbear's bundled
  `libtomcrypt.a`/`libtommath.a` are plain, non-LTO archives placed once at
  the end of the link line, and gcc's LTO recompilation discovers its need
  for their symbols too late for that single archive scan. Fixable, but
  needs a patch to dropbear's own `Makefile.in` (wrap those archives in
  `-Wl,--start-group`/`--end-group`), not just a `CFLAGS`/`LDFLAGS` change.
- `-fno-unwind-tables -fno-asynchronous-unwind-tables`: passed everywhere
  locally (real ~40-100 KB savings on x86_64/i686/aarch64, a byte-identical
  no-op on armv7/armv5/mips/mipsel) but hung a real GitHub Actions runner
  indefinitely mid SFTP-transfer on `WITH_SFTP=1` mips/mipsel, under
  `qemu-mips-static` — never reproduced locally. Reverted outright rather
  than ship something that passed local testing but hangs in CI.

## How the source is modified

Dropbear is patched by `patches/embedded-slots.patch` (applies to a pristine
2026.94 tree) to read each credential from its slot instead of a file:
`load_embedded_identity` (client), the host-key fallback (`svr-runopts.c`), and
the embedded `authorized_keys` check (`svr-authpubkey.c`). The slots themselves
are generated by `gen_cred_slots.sh` into `src/embedded_slots.h`.

## SFTP (optional, opt-in)

Dropbear has no SFTP of its own — the server only offers the subsystem by
exec'ing an external `sftp-server`, and there is no sftp client. Rather than
ship OpenSSH's `sftp` and `sftp-server` as two extra static binaries, they're
compiled straight into `dropbearmulti` as two more multi-call applets
(alongside `dbclient`/`dropbear`/`dropbearkey`/`dropbearconvert`):

```sh
WITH_SFTP=1 client/build.sh x86_64
```

`dropbearmulti sftp` and `dropbearmulti sftp-server` (or a same-named symlink
to it — multi-call dispatch keys off `basename(argv[0])`) now exist. On the
device, `bootstrap.sh --serve` symlinks `/tmp/sftp-server` straight to
`dropbearmulti` (the compiled-in `SFTPSERVER_PATH`), so an incoming SFTP
session to the embedded server works; outbound, `dropbearmulti sftp -S
./dbclient user@host` routes an SFTP client session over dbclient — one
binary plays all three roles.

> `sftp -S` execs its argument directly with ssh-style arguments, without
> inserting a subcommand name — so the transport must be a binary or symlink
> literally named `dbclient` (or `ssh`) for dropbearmulti's multi-call
> dispatch to recognize it; that's the one symlink `WITH_SFTP=1` still adds to
> the package.

Merging two independent codebases into one binary means resolving the
symbols they'd otherwise each have to themselves — see
[`build.sh`](build.sh)'s merge step for the two real collisions this
surfaced: `atomicio` (both projects have their own) and, more subtly,
`sftp_realpath` — the sftp *client*'s `sftp_realpath(conn, path)` and the sftp
*server*'s unrelated `sftp_realpath(path, resolved)` share a name by
coincidence; left unrenamed, the server's calls silently resolved to the
client's function instead, corrupting a path string into a fake connection
handle. Found by an actual SFTP session crashing under a debugger, not by
code inspection — symbol-name collisions between two unrelated codebases
don't show up any other way.

`WITH_SFTP` is off by default (so it can never break the core `dropbearmulti`
build) but *is* in the CI matrix, as the `build-sftp` job.

## Status

- **Proven:** the slot mechanism end-to-end on x86_64 — a key patched in with
  both `patch-cred` (dd) and raw `sed` is loaded by `dbclient` and authenticates
  to OpenSSH; a wrong or empty slot is correctly inactive.
- **Proven:** the 7-arch matrix and the release workflow (client-v0.1.0).
- **Proven in CI, all 7 arches, under `qemu-<arch>-static`:** the
  credential-slot mechanism end-to-end — both `patch-cred` and raw `sed`
  patch a live identity/hostkey/authorized_key, and `dbclient` authenticates
  against the embedded server both times (`client/verify.sh`, the `build`
  matrix job).
- **Proven in CI, all 7 arches, under `qemu-<arch>-static`:** the optional
  SFTP merge. With `WITH_SFTP=1`, OpenSSH's `sftp`/`sftp-server` are compiled
  into `dropbearmulti` itself as two more applets — the embedded server
  accepts an incoming SFTP session via a `/tmp/sftp-server` symlink to
  `dropbearmulti`, and `dropbearmulti sftp -S ./dbclient` uploads a file
  outbound whose content round-trips correctly (`client/verify-sftp.sh`, the
  `build-sftp` matrix job).

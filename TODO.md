# TODO



## client/ — size: two attempts, both reverted

- [x] Tried `-flto` on the core build, all 7 arches — **reverted, doesn't
      link**: dropbear's bundled `libtomcrypt.a`/`libtommath.a` are non-LTO
      archives at the end of the link line; LTO's recompilation discovers it
      needs their symbols after the linker's single archive scan already
      passed them by (`undefined reference` into an `<artificial>`
      LTO-merged unit). Real fix needs `-Wl,--start-group`/`--end-group`
      around those archives, which means patching dropbear's own
      `Makefile.in` — bigger than a CFLAGS change, not done. Never tried on
      `WITH_SFTP=1` at all: LTO compiles from an object's embedded IR at
      final-link time, which would ignore the `objcopy --redefine-sym`
      renames the SFTP merge depends on (they only touch the ELF symbol
      table) — could silently resurrect the atomicio/sftp_realpath
      collisions documented below.
- [x] Tried `-fno-unwind-tables -fno-asynchronous-unwind-tables` on both the
      dropbear and OpenSSH sides — real savings on x86_64/i686/aarch64
      (40-100 KB), byte-identical no-op on armv7/armv5/mips/mipsel. Passed
      **locally** on all 7 arches (`verify.sh` + `verify-sftp.sh`, core and
      WITH_SFTP=1) — pushed, and the real GitHub Actions run hung
      indefinitely: `build mips (SFTP)` and `build mipsel (SFTP)` both got
      stuck for 65+ minutes with server.log showing "Connected to
      127.0.0.1." and then nothing — auth succeeded, the SFTP data transfer
      itself never completed, never reproduced locally. `verify.sh` (login
      only, no SFTP) passed fine on mips/mipsel in the same run, so it's
      specific to the SFTP data-transfer path + qemu-mips-static + this
      flag combination. Cancelled the run, **reverted both sides outright**
      rather than guess a scoped fix (e.g. dropbear-only, skip OpenSSH's
      side) through another slow, hang-risking CI cycle. If revisited: try
      the flags on dropbear's side only (proven safe even on mips there) and
      leave OpenSSH's CFLAGS alone.

## client/ — push and release (nothing is on GitHub yet)

- [x] `chmod +x client/build.sh client/build-sftp.sh client/bootstrap.sh client/patch-cred client/gen_cred_slots.sh`
- [x] Local smoke test: `client/build.sh x86_64` → expect `client/out/dropbear-tunnel-x86_64.tgz`
      (reuse existing deps: copy `/home/q/ssh/dropbear-2026.94.tar.bz2` into
      `client/src-cache/`, symlink `/home/q/ssh/toolchain/x86-64--musl--stable-2025.08-1`
      into `client/toolchain/`)
      — FOUND & FIXED a real bug: `load_embedded_identity()` (cli-runopts.c) was
      called before its own definition with no prototype anywhere →
      `implicit declaration of function` (hard error on modern GCC). Fixed by
      having `gen_cred_slots.sh` emit a forward declaration into the generated
      `embedded_slots.h` (which cli-runopts.c already includes). Rebuilt clean:
      `dropbear-tunnel-x86_64.tgz` (228K) → static stripped ELF, all three
      markers (`id`/`hk`/`ak`) present, `dbclient -h` runs.
- [x] `git add client .github/workflows/client.yml .gitignore`
- [x] `git commit -m "client: static multi-arch Dropbear with runtime-patchable key slots"`
- [x] `git push` (a22a06c)
- [x] `git tag client-v0.1.0 && git push origin client-v0.1.0` (triggers the release job)
- [x] Watch CI: matrix `x86_64 i686 armv7 armv5 aarch64 mips mipsel` all green
- [x] Verify the release has `dropbear-tunnel-<arch>.tgz` + `.sha256` for all 7,
      plus `patch-cred` and `bootstrap.sh` — confirmed via `gh release view client-v0.1.0`

## client/ — SFTP (opt-in)

- [x] Prove `WITH_SFTP=1 client/build.sh x86_64` builds static OpenSSH
      `sftp` + `sftp-server` — built clean on the **first try**, no fix needed
- [x] Confirm the embedded Dropbear server offers the SFTP subsystem via
      `/tmp/sftp-server` after staging it (uploaded a file over a live SFTP
      session, verified content on disk)
- [x] Confirm `sftp -S ./dbclient user@host` works as the client path —
      **found & fixed a real doc/packaging bug**: `sftp -S` execs its argument
      directly with ssh-style args (no subcommand inserted), so the target
      must be a binary/symlink literally named `dbclient` for dropbearmulti's
      multi-call dispatch to work; `./dropbearmulti` itself just prints usage.
      Fixed by having `build.sh` package a `dbclient -> dropbearmulti` symlink
      when `WITH_SFTP=1`, and corrected the README example.
- [x] Extended to the other 6 arches (all 7 build clean with `WITH_SFTP=1`)
      and added a `build-sftp` matrix job to CI (`client/verify-sftp.sh`,
      proven locally under `qemu-<arch>-static` for all 7 before wiring it in)
- [x] Release as `client-v0.2.0` — tagged, pushed, all 14 jobs green, release
      published: 7 core + 7 SFTP tarballs (each with `.sha256`), plus
      `patch-cred` and `bootstrap.sh`

## client/ — verification to add (mirror the server project's rigor)

- [x] End-to-end test in CI: patch each slot (`id`, `hk`, `ak`) with `patch-cred`
      AND raw `sed`, then prove `dbclient` logs in with the swapped `id` key,
      the embedded server presents the swapped `hk`, and accepts the swapped `ak`
      — `client/verify.sh`, wired into the `build` matrix job for all 7 arches
- [x] Assert on each built binary: all three markers present, file size
      unchanged after a patch, ELF still valid — done in `verify.sh` (patch-cred
      path) and confirmed by hand for the raw-sed path on all 7 arches
- [x] Smoke-run each arch's `dropbearmulti` under `qemu-<arch>-static` in CI
      — confirmed green on GitHub Actions: all 14 jobs (7-arch `build` +
      7-arch `build-sftp`) passed, including the nested `sftp`→`dbclient` exec
      via binfmt_misc from the `qemu-user-static` apt package.
      Took 3 real bugs to get there, all found via CI-only failures the local
      dev box never hit:
      1. a bare `exec 3>&-` in the parent shell tried to close an fd that
         only ever existed inside the subshell that opened it — bash treats a
         redirection error on a bare `exec` (no command, only redirections)
         as fatal to the *shell*, unconditionally, bypassing `|| true` and
         invisible to any trap. Silently killed every run on a clean shell;
         "worked" locally only because that interactive shell happened to
         already have fd 3 open from something else.
      2. an `ERR` trap doesn't fire inside functions/subshells without
         `set -o errtrace` (`-E`) — needed to even see bug #1 wasn't a normal
         command failure.
      3. both verify scripts hardcoded `q@127.0.0.1` for the test login (my
         username on the dev box) — the GitHub Actions runner's account is
         `runner`, and dropbear rejects a login name with no matching local
         account before auth is even attempted. Fixed by resolving the
         login user via `id -un`.

## client/ — SFTP merged into dropbearmulti (single binary, not 3)

Follow-up to the SFTP section above: instead of shipping `dropbearmulti` +
`sftp` + `sftp-server` as three separate static binaries, OpenSSH's sftp
client/server objects are now linked directly into `dropbearmulti` as two
more multi-call applets ("sftp", "sftp-server"). One file does everything;
packaging drops to just `dropbearmulti` + a `dbclient` symlink (still needed
because `sftp -S` execs its argument directly and needs that exact name).

- [x] Merge implemented in `build.sh`: builds OpenSSH's objects, resolves
      symbol collisions with `objcopy --redefine-sym`, relinks dropbearmulti
      with them spliced in. New files: `patches/embedded-sftp-dispatch.patch`
      (adds "sftp"/"sftp-server" to dbmulti.c's dispatch table),
      `patches/sftp-glue.c` (stands in for sftp-server-main.c, whose own
      `main()` we can't link). `build-sftp.sh` deleted — superseded.
- [x] Found and fixed **two real symbol collisions**, both only surfacing as
      runtime failures, not link errors:
      1. `atomicio` — both Dropbear and OpenSSH have their own. Mechanical
         fix, renamed OpenSSH's copy everywhere via objcopy.
      2. `sftp_realpath` — an OpenSSH-*internal* collision nothing in the
         Dropbear-vs-OpenSSH symbol diff could catch: the sftp *client*'s
         `sftp_realpath(struct sftp_conn *, path)` and the sftp *server*'s
         unrelated `sftp_realpath(path, resolved)` share a name by pure
         coincidence. Merged, sftp-client.o's copy (a loose, always-linked
         object) silently won for *every* caller, so the server's realpath
         handler called the client's function with a `char *` where it
         expected a `struct sftp_conn *` — the path string got read as
         connection state (garbage fd), crashing with a fatal deep inside
         `send_msg`. Found via `gdb` (`catch syscall writev` + breaking on
         `do_log` for a real backtrace — musl's raw syscall stubs have no
         unwind info, so breaking one frame up was necessary), replaying the
         exact captured protocol bytes from a failing session. General
         lesson: when merging two codebases into one binary, the dangerous
         symbols are ones defined in an always-linked *loose* object that
         are *also* defined somewhere in a linked static archive — that
         mechanical check (`nm` loose objects vs `nm` the archives,
         intersect) is what actually finds these; comparing only "my code"
         vs "their code" externally-visible symbols misses internal ones.
      3. (Caught before it ran once) objcopy takes at most one positional
         file argument — a second one is an *output* path, not a second
         input to also rename. Passing two input files silently overwrote
         one with a renamed copy of the other instead of erroring.
- [x] Verified on all 7 arches under `qemu-<arch>-static`: `verify.sh` (core
      slot mechanism) and `verify-sftp.sh` (real SFTP put + realpath) both
      updated for the single-binary shape and passing.

## Done (for reference)

- Server project `sshd-tunel` v0.2.1 — published and complete.
- client/ slot mechanism proven by hand on x86_64: base64 slot swapped with
  both `patch-cred` (dd) and raw `sed`, loaded by `dbclient`, authenticated to
  OpenSSH; wrong/empty slot correctly inactive.
- client/ scaffold authored: build.sh (7 arch), bootstrap.sh, patch-cred,
  gen_cred_slots.sh, patches/embedded-slots.patch, localoptions.h,
  README.md, .github/workflows/client.yml, .gitignore.

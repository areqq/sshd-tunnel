/*
 * A correct pipe() for MIPS o32, overriding the one zig 0.16.0 supplies.
 *
 * On the MIPS o32 ABI, pipe(2) is the odd syscall out: it does not write the
 * two descriptors through a pointer, it returns them in registers v0 and v1.
 * musl knows this and has a hand-written wrapper for it. zig 0.16.0's own C
 * runtime (libzigc) links ahead of musl and provides a pipe() that uses the
 * ordinary pointer convention, so on mips and mipsel it leaves the caller's
 * array untouched, returns the read descriptor as if it were a status code and
 * leaks the write descriptor.
 *
 * The damage that does is quiet and specific: authentication, key exchange and
 * the whole socket path are unaffected, so a session opens and closes
 * normally, but the server's child process has no working pipe to write to and
 * the command output never reaches the client. That is what it looked like
 * from the outside — a login that succeeds, an "Exited normally" in the server
 * log, and nothing on stdout.
 *
 * This file is a loose object in the link line, so it resolves pipe() for
 * every caller before any archive is consulted. Implemented as musl does it,
 * on the raw syscall rather than on pipe2(), so it does not raise the kernel
 * floor for the old devices this project targets (pipe2 arrived in 2.6.27).
 *
 * build.sh links this in for mips and mipsel only. Covered by
 * patches/mips-o32-pipe-test.c, run under qemu at build time.
 */

#if !defined(__mips__)
#error "mips-o32-pipe.c is for MIPS targets only"
#endif
#if defined(_ABIO32) && _MIPS_SIM != _ABIO32
#error "this wrapper is for the o32 ABI, where pipe(2) returns both descriptors in registers"
#endif

#include <errno.h>

/* o32 __NR_pipe. The o32 syscall numbers start at 4000. */
#define MIPS_O32_NR_pipe 4042

int
pipe(int fd[2])
{
	register long v0 __asm__("$2") = MIPS_O32_NR_pipe; /* syscall no., then first result */
	register long v1 __asm__("$3");                    /* second result */
	register long a3 __asm__("$7");                    /* error flag */

	/*
	 * MIPS signals a failed syscall by setting a3 non-zero and putting the
	 * error number in v0. The clobber list covers the caller-saved registers
	 * the kernel is free to trample.
	 */
	__asm__ __volatile__ (
		"syscall"
		: "+r"(v0), "=r"(v1), "=r"(a3)
		:
		: "$1", "$8", "$9", "$10", "$11", "$12", "$13", "$14", "$15",
		  "$24", "$25", "hi", "lo", "memory"
	);

	if (a3 != 0) {
		errno = (int)v0;
		return -1;
	}
	fd[0] = (int)v0;
	fd[1] = (int)v1;
	return 0;
}

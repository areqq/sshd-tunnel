/*
 * The legacy __sync_* atomic builtins for pre-ARMv6 targets (armv5).
 *
 * ARMv5 has no LDREX/STREX, so clang cannot inline an atomic compare-and-swap
 * and emits a call to the legacy __sync_* libcall instead. GCC answers those
 * from libgcc; zig's compiler-rt does not implement them (as of 0.16.0), while
 * zig's own C runtime (libzigc, whose SmpAllocator backs malloc) calls them —
 * so linking dropbearmulti for armv5 fails with three undefined symbols:
 *
 *   __sync_val_compare_and_swap_4
 *   __sync_val_compare_and_swap_1
 *   __sync_lock_test_and_set_1
 *
 * This file supplies exactly those three, the same way libgcc's
 * config/arm/linux-atomic.c does: through the kernel's user-helper page, whose
 * __kuser_cmpxchg is atomic with respect to interrupts and preemption on a CPU
 * that has no atomic instruction of its own. The helper is a fixed address the
 * kernel maps into every process (CONFIG_KUSER_HELPERS, on by default and
 * effectively always present on the ARMv5 kernels these devices run; there is
 * no alternative for that CPU). qemu-arm implements it too, so the CI/qemu
 * runs exercise the real code path.
 *
 * Word-sized cmpxchg maps straight onto the helper. The byte-sized operations
 * are built on it the way libgcc does: read the containing aligned word,
 * splice the new byte in, and cmpxchg the whole word, retrying while another
 * context changes it.
 *
 * Only reached on armv5 — every other architecture this project builds for
 * (armv7, aarch64, mips, mipsel, i686, x86_64) has native atomics, and
 * build.sh links this in for armv5 alone.
 */

#if !defined(__arm__)
#error "arm-pre-v6-sync.c is for ARM targets only"
#endif
#if defined(__ARMEB__)
#error "big-endian ARM is not a target of this project; the byte shifts below assume little-endian"
#endif

/*
 * int __kuser_cmpxchg(int oldval, int newval, volatile int *ptr)
 * Stores newval at *ptr if *ptr still equals oldval. Returns zero when the
 * exchange happened, non-zero when it did not.
 */
typedef int kuser_cmpxchg_t(int oldval, int newval, volatile int *ptr);
#define kuser_cmpxchg (*(kuser_cmpxchg_t *)0xffff0fc0u)

/* __sync_* are specified as full barriers. These CPUs are single-core and in
 * order, so keeping the compiler from moving memory accesses across the call
 * is all that is left to do. */
#define compiler_barrier() __asm__ __volatile__("" ::: "memory")

int
dbt_sync_val_compare_and_swap_4(volatile int *ptr, int oldval, int newval)
{
	compiler_barrier();
	for (;;) {
		int actual = *ptr;
		if (actual != oldval) {
			compiler_barrier();
			return actual;
		}
		if (kuser_cmpxchg(actual, newval, ptr) == 0) {
			compiler_barrier();
			return oldval;
		}
	}
}

/* The aligned word holding *ptr, and the shift of that byte within it. */
#define BYTE_WORD(p)  ((volatile int *)((unsigned long)(p) & ~3UL))
#define BYTE_SHIFT(p) ((unsigned int)(((unsigned long)(p) & 3UL) * 8U))

unsigned char
dbt_sync_val_compare_and_swap_1(volatile unsigned char *ptr, unsigned char oldval,
    unsigned char newval)
{
	volatile int *word = BYTE_WORD(ptr);
	unsigned int shift = BYTE_SHIFT(ptr);
	unsigned int mask = 0xffU << shift;

	compiler_barrier();
	for (;;) {
		unsigned int old_word = (unsigned int)*word;
		unsigned char actual = (unsigned char)((old_word & mask) >> shift);
		unsigned int new_word;

		if (actual != oldval) {
			compiler_barrier();
			return actual;
		}
		new_word = (old_word & ~mask) | ((unsigned int)newval << shift);
		if (kuser_cmpxchg((int)old_word, (int)new_word, word) == 0) {
			compiler_barrier();
			return oldval;
		}
	}
}

unsigned char
dbt_sync_lock_test_and_set_1(volatile unsigned char *ptr, unsigned char newval)
{
	volatile int *word = BYTE_WORD(ptr);
	unsigned int shift = BYTE_SHIFT(ptr);
	unsigned int mask = 0xffU << shift;

	compiler_barrier();
	for (;;) {
		unsigned int old_word = (unsigned int)*word;
		unsigned char actual = (unsigned char)((old_word & mask) >> shift);
		unsigned int new_word =
		    (old_word & ~mask) | ((unsigned int)newval << shift);

		if (kuser_cmpxchg((int)old_word, (int)new_word, word) == 0) {
			compiler_barrier();
			return actual;
		}
	}
}

/*
 * The definitions above carry dbt_-prefixed names because clang refuses to let
 * a translation unit define a function it knows as a builtin ("cannot
 * redeclare builtin function", and -fno-builtin does not lift that). The
 * linker only cares about the symbol, so publish the three names it is looking
 * for as assembler-level aliases of those definitions.
 */
__asm__(
	".globl __sync_val_compare_and_swap_4\n"
	".set   __sync_val_compare_and_swap_4, dbt_sync_val_compare_and_swap_4\n"
	".globl __sync_val_compare_and_swap_1\n"
	".set   __sync_val_compare_and_swap_1, dbt_sync_val_compare_and_swap_1\n"
	".globl __sync_lock_test_and_set_1\n"
	".set   __sync_lock_test_and_set_1, dbt_sync_lock_test_and_set_1\n"
);

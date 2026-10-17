/*
 * Semantics test for arm-pre-v6-sync.c, run by build.sh under qemu-arm-static
 * whenever the armv5 target is built (skipped, with a notice, if qemu is not
 * installed). Hand-written atomics are worth a test of their own: a wrong
 * return value from a compare-and-swap would not stop dropbearmulti from
 * linking or from logging in, it would corrupt zig's allocator state under
 * contention.
 *
 * Calls the dbt_-prefixed definitions rather than the __sync_* aliases they
 * publish, because clang refuses to let C code even declare a name it knows as
 * a builtin. Same functions, same code path.
 */
#include <stdio.h>
#include <string.h>
int dbt_sync_val_compare_and_swap_4(volatile int *, int, int);
unsigned char dbt_sync_val_compare_and_swap_1(volatile unsigned char *, unsigned char, unsigned char);
unsigned char dbt_sync_lock_test_and_set_1(volatile unsigned char *, unsigned char);
static int fails;
#define CHECK(what, got, want) do { long g=(long)(got), w=(long)(want); \
  if (g!=w) { printf("FAIL %s: got %ld want %ld\n", what, g, w); fails++; } } while (0)
int main(void) {
	volatile int w = 100;
	CHECK("cas4 success returns old", dbt_sync_val_compare_and_swap_4(&w, 100, 200), 100);
	CHECK("cas4 success stored", w, 200);
	CHECK("cas4 failure returns actual", dbt_sync_val_compare_and_swap_4(&w, 999, 300), 200);
	CHECK("cas4 failure left value", w, 200);
	/* every byte offset in a word, to exercise the shift/mask paths */
	for (int off = 0; off < 4; off++) {
		volatile unsigned char buf[8];
		memset((void *)buf, 0xAA, sizeof buf);
		volatile unsigned char *p = &buf[off];
		CHECK("cas1 success returns old", dbt_sync_val_compare_and_swap_1(p, 0xAA, 0x5B), 0xAA);
		CHECK("cas1 success stored", *p, 0x5B);
		CHECK("cas1 failure returns actual", dbt_sync_val_compare_and_swap_1(p, 0x11, 0x22), 0x5B);
		CHECK("cas1 failure left value", *p, 0x5B);
		CHECK("tas1 returns old", dbt_sync_lock_test_and_set_1(p, 0x7C), 0x5B);
		CHECK("tas1 stored", *p, 0x7C);
		/* neighbours in the same word must be untouched */
		for (unsigned i = 0; i < sizeof buf; i++)
			if (&buf[i] != p) CHECK("neighbour byte intact", buf[i], 0xAA);
	}
	printf(fails ? "FAILURES: %d\n" : "all atomics checks passed\n", fails);
	return fails != 0;
}

/*
 * Smoke test for the libc calls dropbear's server-side session path depends
 * on, and in particular for the pipe() override in mips-o32-pipe.c: it checks
 * that pipe() reports success, that both descriptors it hands back actually
 * work, and that a forked child's stdout reaches the parent through one --
 * which is the exact shape of what the server does with a command, and the
 * exact thing that silently produced empty output before the override.
 *
 * The rest (dup, dup2, fcntl, socketpair, poll, select, getpwuid, fork,
 * execlp, waitpid) is here because those are the other calls that path makes;
 * they all passed on zig 0.16.0/MIPS, and this keeps it that way.
 *
 * Built and run under qemu-mips(el)-static by build.sh for the mips and mipsel
 * targets.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <pwd.h>
static int fails;
#define OK(cond, name) do { if (cond) printf("  ok   %s\n", name); \
	else { printf("  FAIL %s (errno=%d %s)\n", name, errno, strerror(errno)); fails++; } } while (0)
int main(void) {
	int fd[2];
	OK(pipe(fd) == 0, "pipe");
	OK(write(fd[1], "x", 1) == 1, "write to pipe");
	char c = 0; OK(read(fd[0], &c, 1) == 1 && c == 'x', "read from pipe");
	int d = dup(fd[0]); OK(d >= 0, "dup");
	OK(dup2(fd[0], 9) == 9, "dup2");
	OK(fcntl(fd[0], F_SETFL, O_NONBLOCK) == 0, "fcntl F_SETFL");
	OK(close(d) == 0 && close(9) == 0, "close");
	int sp[2];
	OK(socketpair(AF_UNIX, SOCK_STREAM, 0, sp) == 0, "socketpair");
	OK(write(sp[0], "y", 1) == 1 && read(sp[1], &c, 1) == 1 && c == 'y', "socketpair round-trip");
	struct pollfd pfd = { .fd = sp[1], .events = POLLOUT };
	OK(poll(&pfd, 1, 100) == 1, "poll");
	fd_set rs; FD_ZERO(&rs); FD_SET(sp[1], &rs);
	struct timeval tv = { 0, 1000 };
	OK(select(sp[1] + 1, NULL, &rs, NULL, &tv) >= 0, "select");
	struct passwd *pw = getpwuid(getuid());
	OK(pw != NULL && pw->pw_name != NULL && pw->pw_shell != NULL, "getpwuid");
	OK(getuid() == geteuid() || 1, "getuid/geteuid ran");
	/* fork + exec + collect the child's output, the actual server-side shape */
	int out[2];
	OK(pipe(out) == 0, "pipe for child stdout");
	pid_t p = fork();
	OK(p >= 0, "fork");
	if (p == 0) {
		dup2(out[1], 1); close(out[0]); close(out[1]);
		execlp("/bin/sh", "sh", "-c", "echo CHILD_SAYS_HI", (char *)NULL);
		_exit(127);
	}
	close(out[1]);
	char buf[64] = {0};
	ssize_t n = read(out[0], buf, sizeof buf - 1);
	int st = 0; waitpid(p, &st, 0);
	OK(n > 0 && strstr(buf, "CHILD_SAYS_HI") != NULL, "child stdout arrived through the pipe");
	OK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "waitpid reaped a normal exit");
	printf(fails ? "FAILURES: %d\n" : "all syscall checks passed\n", fails);
	return fails != 0;
}

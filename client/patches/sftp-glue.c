/* sftp-glue.c - compiled against OpenSSH's own build tree (its includes,
 * its config.h), NOT Dropbear's. Provides the two symbols dropbearmulti's
 * dispatcher (dbmulti.c, patched by embedded-sftp-dispatch.patch) needs to
 * run the SFTP server subsystem in-process:
 *
 *   - cleanup_exit(): OpenSSH's log.c calls this by name on a fatal log
 *     event. The normal entry point (sftp-server-main.c) supplies it, but
 *     that file also brings its own conflicting main() — we don't link it,
 *     so we supply this one function from it instead.
 *   - ossh_sftp_server_main(): what sftp-server-main.c's main() did, minus
 *     the name collision with dropbear's own main().
 *
 * sftp.c's main() is handled separately, by renaming its `main` symbol to
 * `ossh_sftp_main` with objcopy at build time (see build.sh) — its logic
 * isn't small enough to be worth reimplementing here.
 */
#include "includes.h"

#include <sys/types.h>
#include <pwd.h>
#include <stdio.h>
#include <unistd.h>

#include "sftp.h"
#include "misc.h"

void
cleanup_exit(int i)
{
	sftp_server_cleanup_exit(i);
}

int
ossh_sftp_server_main(int argc, char **argv)
{
	struct passwd *user_pw;

	sanitise_stdfd();

	if ((user_pw = getpwuid(getuid())) == NULL) {
		fprintf(stderr, "No user found for uid %lu\n",
		    (unsigned long)getuid());
		return 1;
	}

	return sftp_server_main(argc, argv, user_pw);
}

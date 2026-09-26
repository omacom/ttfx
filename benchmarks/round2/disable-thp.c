/* Optional benchmark control, applied equally to both subprocesses.
 * This changes only the current process and its children, not system policy.
 * cc -shared -fPIC benchmarks/round2/disable-thp.c -o target/disable-thp.so
 */
#include <sys/prctl.h>
#include <unistd.h>

__attribute__((constructor)) static void disable_thp(void) {
    if (prctl(PR_SET_THP_DISABLE, 1UL, 0UL, 0UL, 0UL) != 0) {
        static const char message[] = "Could not disable THP for benchmark control\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(125);
    }
}

/* Measure exec'd ttfx's peak RSS without inheriting Python's pre-exec RSS. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 2; }
    if (!child) {
        int fd = open("/dev/null", O_WRONLY);
        if (fd < 0 || dup2(fd, STDOUT_FILENO) < 0) _exit(126);
        if (fd != STDOUT_FILENO) close(fd);
        execv(argv[1], argv + 1);
        perror("execv");
        _exit(127);
    }
    int status;
    struct rusage usage;
    pid_t waited;
    do { waited = wait4(child, &status, 0, &usage); } while (waited < 0 && errno == EINTR);
    if (waited < 0) { perror("wait4"); return 2; }
    if (!WIFEXITED(status) || WEXITSTATUS(status)) return 1;
    printf("%ld\n", usage.ru_maxrss);
    return 0;
}

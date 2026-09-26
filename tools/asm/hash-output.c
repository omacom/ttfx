/* Native equivalent of hash-output.py for large oracle suites.
 * Build: cc -O2 -Wall -Wextra tools/asm/hash-output.c -lcrypto -o target/hash-output
 * Used only for correctness comparisons, never performance measurements.
 */
#include <errno.h>
#include <inttypes.h>
#include <openssl/evp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t child = -1;

static void fail(const char *operation) {
    /* Distinct diagnostics prevent two wrapper failures from comparing equal. */
    fprintf(stderr, "hash-output wrapper failure pid=%ld: %s (errno=%d)\n",
            (long)getpid(), operation, errno);
    if (child > 0) {
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    }
    exit(125);
}

int main(int argc, char **argv) {
    (void)argc;
    char *binary = getenv("TTFX_ORACLE_REAL_BIN");
    if (!binary || !*binary) fail("TTFX_ORACLE_REAL_BIN is required");
    int pipes[2][2];
    if (pipe(pipes[0]) || pipe(pipes[1])) fail("pipe");
    child = fork();
    if (child < 0) fail("fork");
    if (child == 0) {
        if (dup2(pipes[0][1], STDOUT_FILENO) < 0 ||
            dup2(pipes[1][1], STDERR_FILENO) < 0) fail("dup2");
        for (int i = 0; i < 2; ++i) {
            close(pipes[i][0]);
            close(pipes[i][1]);
        }
        argv[0] = binary;
        execv(binary, argv);
        fail("execv");
    }
    EVP_MD_CTX *hashes[2];
    struct pollfd fds[2];
    uint64_t lengths[2] = {0, 0};
    for (int i = 0; i < 2; ++i) {
        close(pipes[i][1]);
        fds[i] = (struct pollfd){.fd = pipes[i][0], .events = POLLIN};
        hashes[i] = EVP_MD_CTX_new();
        if (!hashes[i] || EVP_DigestInit_ex(hashes[i], EVP_sha256(), NULL) != 1)
            fail("SHA-256 initialization");
    }
    unsigned char buffer[65536];
    int remaining = 2;
    while (remaining) {
        int ready = poll(fds, 2, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            fail("poll");
        }
        for (int i = 0; i < 2; ++i) {
            if (fds[i].revents & POLLNVAL) fail("invalid pipe");
            if (!(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            ssize_t n = read(fds[i].fd, buffer, sizeof(buffer));
            if (n < 0) {
                if (errno == EINTR) continue;
                fail("read");
            }
            if (n == 0) {
                close(fds[i].fd);
                fds[i].fd = -1;
                --remaining;
            } else {
                lengths[i] += (uint64_t)n;
                if (EVP_DigestUpdate(hashes[i], buffer, (size_t)n) != 1)
                    fail("SHA-256 update");
            }
        }
    }
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) fail("waitpid");
    }
    child = -1;
    for (int i = 0; i < 2; ++i) {
        unsigned char digest[EVP_MAX_MD_SIZE];
        unsigned int size;
        if (EVP_DigestFinal_ex(hashes[i], digest, &size) != 1 || size != 32)
            fail("SHA-256 finalization");
        EVP_MD_CTX_free(hashes[i]);
        FILE *out = i == 0 ? stdout : stderr;
        fprintf(out, "%" PRIu64 " ", lengths[i]);
        for (unsigned int j = 0; j < size; ++j) fprintf(out, "%02x", digest[j]);
        fprintf(out, "\n");
        if (fflush(out) || ferror(out)) fail("digest output");
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

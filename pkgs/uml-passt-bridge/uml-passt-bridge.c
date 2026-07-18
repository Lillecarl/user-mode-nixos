#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <signal.h>
#include <sys/wait.h>

static pid_t passt_pid_global;

static void cleanup_passt(void)
{
    if (passt_pid_global > 0) {
        kill(passt_pid_global, SIGTERM);
        sleep(1);
        kill(passt_pid_global, SIGKILL);
    }
}

static int read_exact(int fd, void *buf, size_t len)
{
    size_t total = 0;
    while (total < len) {
        ssize_t n = read(fd, (char *)buf + total, len - total);
        if (n <= 0) return -1;
        total += n;
    }
    return 0;
}

static int write_all(int fd, const void *buf, size_t len)
{
    size_t total = 0;
    while (total < len) {
        ssize_t n = write(fd, (const char *)buf + total, len - total);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            return -1;
        }
        total += n;
    }
    return 0;
}

int main(int argc, char *argv[])
{
    int uml_sv[2], passt_sv[2];
    uint8_t buf[65536];

    if (argc < 2) {
        fprintf(stderr, "Usage: %s UML_BINARY [UML_ARGS...]\n", argv[0]);
        return 1;
    }

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, uml_sv) < 0) {
        perror("socketpair uml");
        return 1;
    }
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, passt_sv) < 0) {
        perror("socketpair passt");
        return 1;
    }

    pid_t passt_pid = fork();
    if (passt_pid < 0) { perror("fork passt"); return 1; }

    if (passt_pid == 0) {
        close(uml_sv[0]); close(uml_sv[1]);
        close(passt_sv[0]);
        if (passt_sv[1] != 4) {
            dup2(passt_sv[1], 4);
            close(passt_sv[1]);
        }
        execlp("passt", "passt",
            "--one-off", "--foreground",
            "--fd", "4",
            "-t", "4325",
            NULL);
        perror("execlp passt");
        _exit(1);
    }
    passt_pid_global = passt_pid;

    pid_t uml_pid = fork();
    if (uml_pid < 0) { perror("fork uml"); return 1; }

    if (uml_pid == 0) {
        close(passt_sv[0]); close(passt_sv[1]);
        close(uml_sv[0]);
        if (uml_sv[1] != 3) {
            dup2(uml_sv[1], 3);
            close(uml_sv[1]);
        }
        fcntl(3, F_SETFD, 0);

        int new_argc = argc;
        char **new_argv = calloc(new_argc + 1, sizeof(char *));
        new_argv[0] = argv[1];
        for (int i = 2; i < argc; i++)
            new_argv[i - 1] = argv[i];
        new_argv[new_argc - 1] = "vec0:transport=fd,fd=3";
        new_argv[new_argc] = NULL;

        execvp(new_argv[0], new_argv);
        perror("execvp uml");
        _exit(1);
    }

    signal(SIGTERM, exit);
    signal(SIGINT, exit);
    atexit(cleanup_passt);

    close(uml_sv[1]);
    close(passt_sv[1]);

    struct pollfd pfds[2];
    pfds[0].fd = uml_sv[0];
    pfds[0].events = POLLIN;
    pfds[1].fd = passt_sv[0];
    pfds[1].events = POLLIN;

    while (1) {
        int ret = poll(pfds, 2, -1);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (pfds[0].revents & (POLLIN | POLLERR | POLLHUP)) {
            ssize_t n = read(uml_sv[0], buf, sizeof(buf));
            if (n <= 0) break;
            uint32_t len_be = htonl(n);
            uint8_t out[sizeof(buf) + 4];
            memcpy(out, &len_be, 4);
            memcpy(out + 4, buf, n);
            if (write_all(passt_sv[0], out, n + 4) < 0) break;
        }

        if (pfds[1].revents & (POLLIN | POLLERR | POLLHUP)) {
            uint32_t len_be;
            if (read_exact(passt_sv[0], &len_be, 4) < 0) break;
            uint32_t len = ntohl(len_be);
            if (len > sizeof(buf)) break;
            if (read_exact(passt_sv[0], buf, len) < 0) break;
            if (write_all(uml_sv[0], buf, len) < 0) break;
        }
    }

    cleanup_passt();
    waitpid(passt_pid_global, NULL, 0);
    waitpid(uml_pid, NULL, 0);
    return 0;
}

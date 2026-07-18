#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <net/ethernet.h>
#include <net/if_arp.h>

struct arp_pkt {
    uint16_t ar_hrd;
    uint16_t ar_pro;
    uint8_t  ar_hln;
    uint8_t  ar_pln;
    uint16_t ar_op;
    uint8_t  ar_sha[ETH_ALEN];
    uint8_t  ar_spa[4];
    uint8_t  ar_tha[ETH_ALEN];
    uint8_t  ar_tpa[4];
} __attribute__((packed));
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/timerfd.h>

#include <slirp/libslirp.h>

#define UML_FD 3
#define MAX_PFDS 64
#define MAX_TIMERS 8

static int uml_fd = -1;
static Slirp *slirp = NULL;
static uint8_t guest_mac[ETH_ALEN];
static uint8_t host_mac[ETH_ALEN];

struct poll_state {
    int nfds;
    struct pollfd pfds[MAX_PFDS];
};

struct timer_info {
    int fd;
    SlirpTimerCb cb;
    void *opaque;
};

static struct timer_info timer_map[MAX_TIMERS];
static int ntimers = 0;

static int64_t clock_get_ns_cb(void *opaque)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static slirp_ssize_t send_packet_cb(const void *buf, size_t len, void *opaque)
{
    slirp_ssize_t ret = write(uml_fd, buf, len);
    if (ret < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
        return 0;
    return ret;
}

static void guest_error_cb(const char *msg, void *opaque)
{
    fprintf(stderr, "slirp: guest error: %s\n", msg);
}

static void *timer_new_cb(SlirpTimerCb cb, void *cb_opaque, void *opaque)
{
    struct poll_state *ps = opaque;
    int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
    if (fd < 0) return NULL;

    int idx = ps->nfds++;
    ps->pfds[idx].fd = fd;
    ps->pfds[idx].events = POLLIN;

    if (ntimers < MAX_TIMERS) {
        timer_map[ntimers].fd = fd;
        timer_map[ntimers].cb = cb;
        timer_map[ntimers].opaque = cb_opaque;
        ntimers++;
    }
    return (void *)(intptr_t)fd;
}

static void timer_free_cb(void *timer, void *opaque)
{
    int fd = (int)(intptr_t)timer;
    close(fd);
    for (int i = 0; i < ntimers; i++) {
        if (timer_map[i].fd == fd) {
            timer_map[i] = timer_map[--ntimers];
            break;
        }
    }
}

static void timer_mod_cb(void *timer, int64_t expire_time, void *opaque)
{
    int fd = (int)(intptr_t)timer;
    struct itimerspec its = {0};
    int64_t now = clock_get_ns_cb(NULL);
    int64_t delta = expire_time - now;
    if (delta < 0) delta = 0;
    its.it_value.tv_sec = delta / 1000000000;
    its.it_value.tv_nsec = delta % 1000000000;
    timerfd_settime(fd, 0, &its, NULL);
}

static void notify_cb(void *opaque)
{
}

static int add_poll_cb(int fd, int events, void *opaque)
{
    struct poll_state *ps = opaque;
    int idx = ps->nfds++;
    ps->pfds[idx].fd = fd;
    ps->pfds[idx].events = 0;
    if (events & SLIRP_POLL_IN) ps->pfds[idx].events |= POLLIN;
    if (events & SLIRP_POLL_OUT) ps->pfds[idx].events |= POLLOUT;
    return idx;
}

static int get_revents_cb(int idx, void *opaque)
{
    struct poll_state *ps = opaque;
    int revents = 0;
    if (ps->pfds[idx].revents & POLLIN) revents |= SLIRP_POLL_IN;
    if (ps->pfds[idx].revents & POLLOUT) revents |= SLIRP_POLL_OUT;
    if (ps->pfds[idx].revents & POLLERR) revents |= SLIRP_POLL_ERR;
    if (ps->pfds[idx].revents & POLLHUP) revents |= SLIRP_POLL_HUP;
    return revents;
}

static void handle_arp(const uint8_t *frame, int len)
{
    if (len < (int)sizeof(struct arp_pkt))
        return;

    struct arp_pkt *arp = (struct arp_pkt *)frame;

    if (ntohs(arp->ar_op) != ARPOP_REQUEST)
        return;

    uint32_t target_ip;
    memcpy(&target_ip, arp->ar_tpa, 4);

    uint32_t vhost = htonl(0x0a000202);

    if (target_ip != vhost)
        return;

    uint8_t reply[sizeof(struct arp_pkt)];
    struct arp_pkt *rarp = (struct arp_pkt *)reply;

    memcpy(rarp, arp, sizeof(struct arp_pkt));
    memcpy(rarp->ar_tha, arp->ar_sha, ETH_ALEN);
    memcpy(rarp->ar_sha, host_mac, ETH_ALEN);
    memcpy(rarp->ar_tpa, arp->ar_spa, 4);
    memcpy(rarp->ar_spa, arp->ar_tpa, 4);
    rarp->ar_op = htons(ARPOP_REPLY);
    rarp->ar_hrd = htons(ARPHRD_ETHER);
    rarp->ar_pro = htons(ETH_P_IP);
    rarp->ar_hln = ETH_ALEN;
    rarp->ar_pln = 4;

    uint8_t eth_frame[ETH_HLEN + sizeof(struct arp_pkt)];
    struct ether_header *eh = (struct ether_header *)eth_frame;
    memcpy(eh->ether_dhost, arp->ar_sha, ETH_ALEN);
    memcpy(eh->ether_shost, host_mac, ETH_ALEN);
    eh->ether_type = htons(ETH_P_ARP);
    memcpy(eth_frame + ETH_HLEN, reply, sizeof(struct arp_pkt));

    write(uml_fd, eth_frame, sizeof(eth_frame));
}

static void process_uml_frame(const uint8_t *buf, int len)
{
    if (len < ETH_HLEN)
        return;

    struct ether_header *eh = (struct ether_header *)buf;
    uint16_t ether_type = ntohs(eh->ether_type);
    const uint8_t *payload = buf + ETH_HLEN;
    int payload_len = len - ETH_HLEN;

    memcpy(guest_mac, eh->ether_shost, ETH_ALEN);

    if (ether_type == ETH_P_ARP) {
        handle_arp(payload, payload_len);
    } else if (ether_type == ETH_P_IP) {
        slirp_input(slirp, payload, payload_len);
    }
}

struct process_pollfd {
    struct pollfd *pfds;
    int num;
};

static void run_slirp_loop(int fd)
{
    uml_fd = fd;

    host_mac[0] = 0x52; host_mac[1] = 0x54;
    host_mac[2] = 0x00; host_mac[3] = 0x12;
    host_mac[4] = 0x34; host_mac[5] = 0x56;

    struct SlirpConfig cfg = {
        .version = SLIRP_CONFIG_VERSION_MAX,
        .restricted = 0,
        .in_enabled = true,
        .vnetwork = { .s_addr = htonl(0x0a000200) },   /* 10.0.2.0 */
        .vnetmask = { .s_addr = htonl(0xffffff00) },    /* 255.255.255.0 */
        .vhost = { .s_addr = htonl(0x0a000202) },       /* 10.0.2.2 */
        .in6_enabled = false,
        .vhostname = "uml",
        .tftp_server_name = NULL,
        .tftp_path = NULL,
        .bootfile = NULL,
        .vdhcp_start = { .s_addr = htonl(0x0a00020f) }, /* 10.0.2.15 */
        .vnameserver = { .s_addr = htonl(0x0a000203) }, /* 10.0.2.3 */
        .vdnssearch = NULL,
        .vdomainname = NULL,
        .if_mtu = 1500,
        .if_mru = 1500,
        .disable_host_loopback = false,
        .enable_emu = false,
        .outbound_addr = NULL,
        .outbound_addr6 = NULL,
        .disable_dns = false,
        .disable_dhcp = false,
    };

    SlirpCb callbacks = {
        .send_packet = send_packet_cb,
        .guest_error = guest_error_cb,
        .clock_get_ns = clock_get_ns_cb,
        .timer_new = timer_new_cb,
        .timer_free = timer_free_cb,
        .timer_mod = timer_mod_cb,
        .register_poll_fd = NULL,
        .unregister_poll_fd = NULL,
        .notify = notify_cb,
    };

    slirp = slirp_new(&cfg, &callbacks, NULL);
    if (!slirp) {
        fprintf(stderr, "slirp: failed to initialize\n");
        exit(1);
    }

    struct poll_state ps;
    memset(&ps, 0, sizeof(ps));

    uint8_t buf[65536];

    while (1) {
        uint32_t timeout = UINT32_MAX;

        ps.nfds = 0;

        ps.pfds[ps.nfds].fd = uml_fd;
        ps.pfds[ps.nfds].events = POLLIN;
        ps.nfds++;

        slirp_pollfds_fill(slirp, &timeout, add_poll_cb, &ps);

        int ret = poll(ps.pfds, ps.nfds, timeout == UINT32_MAX ? -1 : (int)timeout);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (ps.pfds[0].revents & (POLLIN | POLLERR | POLLHUP)) {
            slirp_ssize_t n = read(uml_fd, buf, sizeof(buf));
            if (n <= 0) break;
            process_uml_frame(buf, n);
        }

        for (int i = 1; i < ps.nfds; i++) {
            if (ps.pfds[i].revents & POLLIN) {
                int tfd = ps.pfds[i].fd;
                uint64_t expirations;
                read(tfd, &expirations, sizeof(expirations));
                for (int j = 0; j < ntimers; j++) {
                    if (timer_map[j].fd == tfd) {
                        timer_map[j].cb(timer_map[j].opaque);
                        break;
                    }
                }
            }
        }

        slirp_pollfds_poll(slirp, (ret < 0), get_revents_cb, &ps);
    }

    slirp_cleanup(slirp);
}

int main(int argc, char *argv[])
{
    int sv[2];

    if (argc < 3) {
        fprintf(stderr, "Usage: %s -- UML_BINARY [UML_ARGS...]\n", argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "--") != 0) {
        fprintf(stderr, "Usage: %s -- UML_BINARY [UML_ARGS...]\n", argv[0]);
        return 1;
    }

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        perror("socketpair");
        return 1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }

    if (pid == 0) {
        close(sv[0]);
        run_slirp_loop(sv[1]);
        _exit(0);
    }

    close(sv[1]);

    if (sv[0] != UML_FD) {
        dup2(sv[0], UML_FD);
        close(sv[0]);
    }

    int new_argc = argc - 2 + 2;
    char **new_argv = calloc(new_argc + 1, sizeof(char *));
    new_argv[0] = argv[2];
    for (int i = 3; i < argc; i++)
        new_argv[i - 2] = argv[i];
    new_argv[new_argc - 1] = "vec0:transport=fd,fd=3";
    new_argv[new_argc] = NULL;

    execvp(new_argv[0], new_argv);
    perror("execvp");
    return 1;
}

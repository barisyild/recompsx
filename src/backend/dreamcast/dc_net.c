/* dc_net.c — the network for the i-mode adaptor's phone (bp_http_*, ADR-0040), over KallistiOS's
 * own TCP.
 *
 * The network comes up at the first request, not at boot, so a game that never goes online never
 * waits for it: net_init brings up the broadband or LAN adaptor and asks DHCP (or the flashrom's
 * settings) for an address, in a thread of its own, while the requests wait — the phone is busy
 * meanwhile. No adaptor, no network: every request then fails, as on a console with no cable.
 *
 * Each handle is one HTTP/1.0 exchange over a non-blocking socket: a dotted address is taken as
 * it is, a name is resolved (the one wait there is), the socket connects in the background, the
 * request goes out as the socket takes it, and the response comes back as it arrives until the
 * server closes. Nothing here blocks the game. */

#include "dc_internal.h"
#include <kos/net.h>
#include <kos/thread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <unistd.h>

#define MAX_HTTP 4
#define HOST_LEN 128

enum { NET_UNTRIED = 0, NET_STARTING = 2, NET_UP = 1, NET_NONE = -1 };
static volatile int g_net = NET_UNTRIED;

typedef struct {
    int used;
    int sock;                     /* -1 until the network is up and the socket opened */
    int connected;
    char host[HOST_LEN];
    int port;
    uint8_t* request;
    int len, sent;
} http_t;

static http_t g_http[MAX_HTTP];

static void* net_start(void* unused) {
    (void)unused;
    g_net = (net_init(0) >= 0 && net_default_dev) ? NET_UP : NET_NONE;
    bp_log(g_net == NET_UP ? BP_LOG_INFO : BP_LOG_WARN,
           g_net == NET_UP ? "net: up" : "net: no network adaptor");
    return NULL;
}

int bp_http_open(const char* host, int port, const uint8_t* request, int len) {
    int h = -1;
    for(int i = 0; i < MAX_HTTP && h < 0; i++) if(!g_http[i].used) h = i;
    if(h < 0 || !host || !*host || strlen(host) >= HOST_LEN || port <= 0 || len <= 0 || g_net == NET_NONE)
        return -1;
    if(g_net == NET_UNTRIED) {
        g_net = NET_STARTING;
        if(!thd_create(1, net_start, NULL)) g_net = NET_NONE;
    }
    uint8_t* copy = (uint8_t*)malloc((size_t)len);
    if(!copy) return -1;
    memcpy(copy, request, (size_t)len);
    http_t* t = &g_http[h];
    memset(t, 0, sizeof *t);
    t->used = 1;
    t->sock = -1;
    snprintf(t->host, sizeof t->host, "%s", host);
    t->port = port;
    t->request = copy;
    t->len = len;
    return h;
}

/* The socket, once the network is up: an address (a dotted one as it is), connecting. */
static int http_start(http_t* t) {
    struct sockaddr_in to;
    memset(&to, 0, sizeof to);
    to.sin_family = AF_INET;
    to.sin_port = htons((uint16_t)t->port);
    if(inet_pton(AF_INET, t->host, &to.sin_addr) != 1) {
        struct addrinfo hints, *found = NULL;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        if(getaddrinfo(t->host, NULL, &hints, &found) != 0 || !found) return -1;
        to.sin_addr = ((struct sockaddr_in*)found->ai_addr)->sin_addr;
        freeaddrinfo(found);
    }
    const int s = socket(AF_INET, SOCK_STREAM, 0);
    if(s < 0) return -1;
    if(fcntl(s, F_SETFL, O_NONBLOCK) != 0 ||
       (connect(s, (struct sockaddr*)&to, sizeof to) != 0 && errno != EINPROGRESS && errno != EAGAIN)) {
        close(s);
        return -1;
    }
    t->sock = s;
    return 0;
}

int bp_http_read(int handle, uint8_t* buf, int cap) {
    if(handle < 0 || handle >= MAX_HTTP || !g_http[handle].used) return -2;
    http_t* t = &g_http[handle];
    if(g_net == NET_STARTING) return 0;
    if(g_net != NET_UP) return -2;
    if(t->sock < 0 && http_start(t) != 0) return -2;
    if(!t->connected) {
        struct pollfd p = { t->sock, POLLOUT, 0 };
        if(poll(&p, 1, 0) <= 0) return 0;
        if(p.revents & (POLLERR | POLLHUP)) return -2;
        t->connected = 1;
    }
    while(t->sent < t->len) {
        const int n = (int)send(t->sock, t->request + t->sent, (size_t)(t->len - t->sent), 0);
        if(n > 0) t->sent += n;
        else if(n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        else return -2;
    }
    const int n = (int)recv(t->sock, buf, (size_t)cap, 0);
    if(n > 0) return n;
    if(n == 0) return -1;
    return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -2;
}

void bp_http_close(int handle) {
    if(handle < 0 || handle >= MAX_HTTP || !g_http[handle].used) return;
    http_t* t = &g_http[handle];
    if(t->sock >= 0) close(t->sock);
    free(t->request);
    memset(t, 0, sizeof *t);
}

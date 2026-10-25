// Clock and socket for tb_link.v (ticket #29): the PC's side of the FT232H
// as a TCP connection on 127.0.0.1 (sim/README.md, "The link on a socket").
//
//   +port=N    listen on port N (default 0: any free port)
//   +maxms=N   give up after N ms of simulated time (default 0: never)
//
// Prints "LISTENING <port>" once the socket is bound, then waits for one
// connection before the clock starts. Every byte the connection sends goes
// to the machine in order (the control commands are bytes like any other:
// the serial unit takes them out); every byte the machine sends goes back.
// The run ends when the connection closes, or at +maxms.
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET sock_t;
#define CLOSESOCK closesocket
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int sock_t;
#define INVALID_SOCKET (-1)
#define CLOSESOCK close
#endif
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <vector>

#include "Vtb_link.h"
#include "verilated.h"

// Needed by verilated.cpp on MinGW, which has no weak symbols
double sc_time_stamp() { return 0; }

static void nonblocking(sock_t s)
{
#ifdef _WIN32
    u_long on = 1;
    ioctlsocket(s, FIONBIO, &on);
#else
    fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK);
#endif
}

static bool would_block()
{
#ifdef _WIN32
    return WSAGetLastError() == WSAEWOULDBLOCK;
#else
    return errno == EAGAIN || errno == EWOULDBLOCK;
#endif
}

int main(int argc, char **argv)
{
    VerilatedContext ctx;
    ctx.commandArgs(argc, argv);
    int port = 0;
    long maxms = 0;
    const char *arg;
    if ((arg = ctx.commandArgsPlusMatch("port=")) && *arg) port = atoi(arg + 6);
    if ((arg = ctx.commandArgsPlusMatch("maxms=")) && *arg) maxms = atol(arg + 7);

#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    sock_t ls = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof one);
    sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = htons((unsigned short)port);
    if (bind(ls, (sockaddr *)&sa, sizeof sa) != 0 || listen(ls, 1) != 0) {
        printf("TEST FAILED: cannot listen on port %d\n", port);
        return 1;
    }
    socklen_t len = sizeof sa;
    getsockname(ls, (sockaddr *)&sa, &len);
    printf("LISTENING %d\n", ntohs(sa.sin_port));
    fflush(stdout);
    sock_t cs = accept(ls, nullptr, nullptr);
    if (cs == INVALID_SOCKET) {
        printf("TEST FAILED: accept\n");
        return 1;
    }
    CLOSESOCK(ls);
    setsockopt(cs, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof one);
    nonblocking(cs);

    Vtb_link top{&ctx};
    std::deque<unsigned char> in;       // PC -> machine
    std::vector<unsigned char> out;     // machine -> PC
    char buf[4096];
    unsigned long long cycles = 0, nin = 0, nout = 0;
    bool open = true;
    top.pc_valid = 0;
    top.pc_byte = 0;
    while (!ctx.gotFinish() && open) {
        top.clk = 0;
        top.eval();
        ctx.timeInc(5);
        top.clk = 1;
        top.eval();
        ctx.timeInc(5);
        cycles++;
        if (top.fpga_strobe) out.push_back(top.fpga_byte);
        if (top.pc_take && !in.empty()) in.pop_front();
        top.pc_valid = !in.empty();
        top.pc_byte = in.empty() ? 0 : in.front();
        if (cycles % 1000 == 0) {       // every 10 us of simulated time
            for (;;) {
                int n = recv(cs, buf, sizeof buf, 0);
                if (n > 0) {
                    in.insert(in.end(), buf, buf + n);
                    nin += n;
                    continue;
                }
                if (n == 0 || !would_block()) open = false;
                break;
            }
            while (!out.empty()) {
                int n = send(cs, (const char *)out.data(), (int)out.size(), 0);
                if (n <= 0) break;
                out.erase(out.begin(), out.begin() + n);
                nout += n;
            }
            top.pc_valid = !in.empty();
            top.pc_byte = in.empty() ? 0 : in.front();
            if (maxms && cycles >= (unsigned long long)maxms * 100000ULL) {
                printf("TEST FAILED: timeout after %ld ms\n", maxms);
                break;
            }
        }
    }
    printf("LINK CLOSED: %llu bytes in, %llu bytes out, %llu clocks (%.1f ms)\n",
           nin, nout, cycles, cycles / 100000.0);
    top.final();
    CLOSESOCK(cs);
    return 0;
}

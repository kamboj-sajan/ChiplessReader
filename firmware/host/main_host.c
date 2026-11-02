/*
 * main_host.c - "virtual reader": the unmodified firmware core running on macOS / Linux.
 *
 * It creates a pseudo-terminal and links it at /tmp/chipless-reader (by default). To the SDK
 * that path behaves exactly like the STM32's USB serial port (/dev/cu.usbmodem...): same
 * bytes, same frames, same replies. The debug console that appears in STM32CubeIDE's SWV
 * window on the real board is printed to this terminal instead.
 *
 *   ./chipless-vreader [--link /tmp/chipless-reader] [--nv FILE] [-v 0|1|2]
 */
#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "../core/platform.h"
#include "../core/app.h"
#include "../core/console.h"
#include "../core/app_config.h"

static int s_master = -1, s_slave = -1;
static const char *s_link = "/tmp/chipless-reader";
static const char *s_nv_path = NULL;
static int s_exit_with_parent = 0;      /* --exit-with-parent: the Mac app's Demo mode */
static struct timespec s_t0;
static volatile sig_atomic_t s_stop = 0;

/* ---------------- platform implementation ---------------- */

uint32_t plat_millis(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint32_t)((t.tv_sec - s_t0.tv_sec) * 1000 + (t.tv_nsec - s_t0.tv_nsec) / 1000000);
}

void plat_delay_us(uint32_t us)
{
    struct timespec t = { (time_t)(us / 1000000u), (long)(us % 1000000u) * 1000L };
    nanosleep(&t, NULL);
}

void plat_link_write(const uint8_t *d, uint16_t n)
{
    uint16_t off = 0;
    int tries = 0;
    while (off < n && tries < 200) {
        ssize_t w = write(s_master, d + off, n - off);
        if (w > 0) { off = (uint16_t)(off + w); continue; }
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { plat_delay_us(1000); tries++; continue; }
        break;
    }
}

void plat_console_write(const char *s, int len)
{
    fwrite(s, 1, (size_t)len, stdout);
    fflush(stdout);
}

/* On the host the SPI bus goes nowhere; the simulated backend observes the words instead. */
void plat_adf4351_write(uint32_t word) { (void)word; }
int  plat_adf4351_lock_detect(void) { return 0; }
void plat_pe4312_write(uint8_t word6) { (void)word6; }
void plat_pa_enable(int on) { (void)on; }
void plat_adc_read(uint16_t *a, uint16_t *b) { *a = 0; *b = 0; }
uint16_t plat_adc_vref_mv(void) { return ADC_VREF_MV; }
void plat_led(int led, int on) { (void)led; (void)on; }
void plat_reset(void) {}

/* the flash sector of the real board becomes a file; without --nv nothing is kept */
int plat_nv_read(void *dst, uint32_t len)
{
    if (!s_nv_path) return -1;
    FILE *f = fopen(s_nv_path, "rb");
    if (!f) return -1;
    size_t got = fread(dst, 1, len, f);
    fclose(f);
    return got == len ? 0 : -1;
}

int plat_nv_write(const void *src, uint32_t len)
{
    if (!s_nv_path) return 0;
    FILE *f = fopen(s_nv_path, "wb");
    if (!f) return -1;
    size_t put = fwrite(src, 1, len, f);
    fclose(f);
    return put == len ? 0 : -1;
}

void plat_get_uid(uint8_t uid[12])
{
    static const uint8_t v[12] = { 'V', 'I', 'R', 'T', 'U', 'A', 'L', 0, 0, 0, 0, 1 };
    memcpy(uid, v, 12);
}

/* ---------------- pseudo-terminal ---------------- */

static void make_raw(int fd)
{
    struct termios t;
    if (tcgetattr(fd, &t) == 0) {
        cfmakeraw(&t);
        cfsetispeed(&t, B115200);
        cfsetospeed(&t, B115200);
        tcsetattr(fd, TCSANOW, &t);
    }
}

static int open_pty(char *slave_name, size_t cap)
{
    s_master = posix_openpt(O_RDWR | O_NOCTTY);
    if (s_master < 0 || grantpt(s_master) != 0 || unlockpt(s_master) != 0) return -1;
    const char *name = ptsname(s_master);
    if (!name) return -1;
    snprintf(slave_name, cap, "%s", name);
    /* keep our own handle on the slave so the pty survives clients connecting/disconnecting */
    s_slave = open(slave_name, O_RDWR | O_NOCTTY);
    if (s_slave < 0) return -1;
    make_raw(s_slave);
    make_raw(s_master);
    fcntl(s_master, F_SETFL, fcntl(s_master, F_GETFL) | O_NONBLOCK);
    return 0;
}

static void on_signal(int sig) { (void)sig; s_stop = 1; }

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--link") && i + 1 < argc) s_link = argv[++i];
        else if (!strcmp(argv[i], "--nv") && i + 1 < argc) s_nv_path = argv[++i];
        else if (!strcmp(argv[i], "--exit-with-parent")) s_exit_with_parent = 1;
        else if (!strcmp(argv[i], "-v") && i + 1 < argc) console_verbose = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("usage: %s [--link PATH] [--nv FILE] [-v 0|1|2]\n"
                   "  --link PATH  symlink for the virtual serial port (default /tmp/chipless-reader)\n"
                   "  --nv FILE    keep settings and the tag database in this file (default: not kept)\n"
                   "  -v N         console detail: 0 commands, 1 + frame hex (default), 2 + every sweep point\n",
                   argv[0]);
            return 0;
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &s_t0);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    char slave[128];
    if (open_pty(slave, sizeof slave) != 0) {
        perror("could not create pseudo-terminal");
        return 1;
    }
    unlink(s_link);
    if (symlink(slave, s_link) != 0) {
        perror("could not create link");
        return 1;
    }

    printf("Virtual reader serial port: %s  (-> %s)\n", s_link, slave);
    printf("Connect the SDK to it, or use Demo mode in the Chipless Reader app.\n\n");
    fflush(stdout);
    app_init("virtual serial port (pty)");

    const pid_t parent = getppid();
    uint8_t buf[512];
    while (!s_stop) {
        if (s_exit_with_parent && getppid() != parent) break;
        struct pollfd p = { s_master, POLLIN, 0 };
        int r = poll(&p, 1, 2);
        if (r > 0 && (p.revents & POLLIN)) {
            ssize_t n = read(s_master, buf, sizeof buf);
            if (n > 0) app_on_rx(buf, (uint32_t)n);
        }
        app_poll();
    }
    unlink(s_link);
    printf("\nvirtual reader stopped\n");
    return 0;
}

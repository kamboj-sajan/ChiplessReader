#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "console.h"
#include "platform.h"

int console_verbose = 1;

static void vout(int stamp, const char *fmt, va_list ap)
{
    char buf[256];
    int n = 0;
    if (stamp) {
        uint32_t ms = plat_millis();
        n = snprintf(buf, sizeof buf, "[%5lu.%03lu] ", (unsigned long)(ms / 1000u), (unsigned long)(ms % 1000u));
    }
    int m = vsnprintf(buf + n, sizeof buf - (size_t)n, fmt, ap);
    if (m < 0) return;
    n += m;
    if (n > (int)sizeof buf - 1) n = (int)sizeof buf - 1;
    plat_console_write(buf, n);
}

void console_printf(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt); vout(1, fmt, ap); va_end(ap);
}

void console_raw(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt); vout(0, fmt, ap); va_end(ap);
}

void console_hex(const char *tag, const uint8_t *d, uint16_t n, const char *suffix)
{
    char line[200];
    int k = snprintf(line, sizeof line, "%-3s ", tag);
    uint16_t shown = n > 24 ? 24 : n;
    for (uint16_t i = 0; i < shown && k < (int)sizeof line - 4; i++)
        k += snprintf(line + k, sizeof line - (size_t)k, "%02X ", d[i]);
    if (shown < n && k < (int)sizeof line - 16)
        k += snprintf(line + k, sizeof line - (size_t)k, "... (%u B) ", (unsigned)n);
    console_printf("%s%s\n", line, suffix ? suffix : "");
}

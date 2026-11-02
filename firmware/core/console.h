#ifndef CONSOLE_H
#define CONSOLE_H
#include <stdint.h>

/* printf to the debug console with a "[  12.345] " timestamp prefix. */
void console_printf(const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;
/* same, without timestamp (continuation lines) */
void console_raw(const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;
/* "[ts] <tag> A5 08 00 ..." hex dump, truncated after max_bytes */
void console_hex(const char *tag, const uint8_t *d, uint16_t n, const char *suffix);

extern int console_verbose;   /* 0 = commands only, 1 = + raw hex, 2 = + per-point sweep */

#endif

#include "crc16.h"

uint16_t crc16_ccitt(const uint8_t *p, size_t n)
{
    uint16_t c = 0xFFFF;
    while (n--) {
        c ^= (uint16_t)((uint16_t)(*p++) << 8);
        for (int i = 0; i < 8; i++)
            c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
    }
    return c;
}

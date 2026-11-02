#ifndef CRC16_H
#define CRC16_H
#include <stdint.h>
#include <stddef.h>

/* CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no xorout.
 * "123456789" -> 0x29B1. Identical to CRC16.ccitt() in the Swift SDK. */
uint16_t crc16_ccitt(const uint8_t *p, size_t n);

#endif

/*
 * protocol.h - frame format shared with the SDK.
 *
 *   A5 | LEN u16 LE | CMD u8 | STATUS u8 | PAYLOAD ... | CRC16 u16 LE
 *   LEN counts CMD..CRC inclusive (= payload + 4). CRC covers CMD..PAYLOAD.
 *   Host->reader: CMD 0x01..0x3F. Reply: CMD | 0x80 (0x81..0xBF). Unsolicited reader->host: 0xC0..0xFF.
 *
 * Full description: docs/PROTOCOL.md
 */
#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>
#include "app_config.h"

/* ---- command codes ---- */
enum {
    CMD_GET_INFO        = 0x01,
    CMD_PING            = 0x02,
    CMD_GET_STATUS      = 0x03,
    CMD_RESET_CONFIG    = 0x05,
    CMD_NV_SAVE         = 0x06,
    CMD_SET_MODE        = 0x08,
    CMD_GET_CONFIG      = 0x0F,
    CMD_SET_SWEEP       = 0x10,
    CMD_SET_TX_POWER    = 0x12,
    CMD_SET_CARRIER     = 0x13,
    CMD_SET_RX_CONFIG   = 0x14,
    CMD_SET_ACQ         = 0x16,
    CMD_SET_DETECT      = 0x18,
    CMD_GET_DETECT      = 0x19,
    CMD_SET_PROFILE     = 0x1A,
    CMD_GET_PROFILE     = 0x1B,
    CMD_SET_CAL         = 0x1E,
    CMD_GET_CAL         = 0x1F,
    CMD_SET_LO          = 0x20,
    CMD_MEASURE         = 0x21,
    CMD_ATTEN_SCAN      = 0x22,
    CMD_AUTO_LEVEL      = 0x23,
    CMD_DB_INFO         = 0x24,
    CMD_DB_GET          = 0x25,
    CMD_DB_PUT          = 0x26,
    CMD_DB_DELETE       = 0x27,
    CMD_DB_CLEAR        = 0x28,
    CMD_READ_TAG        = 0x30,
    CMD_GET_SWEEP_DATA  = 0x31,
    CMD_CAPTURE_BG      = 0x32,
    CMD_CLEAR_BG        = 0x33,
    CMD_SIM_SET         = 0x3A,
    CMD_SIM_GET         = 0x3B,

    RSP_FLAG            = 0x80,
    RSP_INVALID         = 0xBF,   /* reply to a command outside 0x01..0x3F */
    EVT_TAG_REPORT      = 0xC0,
};

/* ---- status codes ---- */
enum {
    ST_OK            = 0x00,
    ST_CRC_ERROR     = 0x01,
    ST_UNKNOWN_CMD   = 0x02,
    ST_BAD_LENGTH    = 0x03,
    ST_OUT_OF_RANGE  = 0x04,
    ST_BUSY          = 0x05,
    ST_PLL_UNLOCKED  = 0x06,
    ST_NOT_SUPPORTED = 0x07,
    ST_NV_ERROR      = 0x08,
};

typedef struct {
    uint8_t  cmd;
    uint8_t  status;
    uint16_t payload_len;
    uint8_t  payload[PROTO_MAX_PAYLOAD];
} frame_t;

typedef enum { PR_NONE = 0, PR_FRAME = 1, PR_CRC_ERROR = 2, PR_OVERSIZE = 3, PR_TIMEOUT = 4 } proto_result_t;

typedef struct {
    int      state;
    uint16_t len;           /* LEN field                                  */
    uint16_t idx;           /* bytes of body received                     */
    uint32_t last_ms;
    uint8_t  body[PROTO_MAX_LEN];
    uint16_t crc_got, crc_want;   /* for diagnostics after PR_CRC_ERROR  */
} proto_parser_t;

void           proto_init(proto_parser_t *p);
/* Feed one byte. Returns PR_FRAME when *out holds a complete valid frame. */
proto_result_t proto_feed(proto_parser_t *p, uint8_t b, uint32_t now_ms, frame_t *out);
/* Build a frame into out (must hold payload_len + 7 bytes). Returns total length. */
uint16_t       proto_build(uint8_t cmd, uint8_t status, const uint8_t *payload,
                           uint16_t payload_len, uint8_t *out);

const char    *proto_cmd_name(uint8_t cmd);
const char    *proto_status_name(uint8_t st);

/* little-endian helpers */
static inline uint16_t rd_u16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t rd_u32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static inline uint8_t *wr_u8 (uint8_t *p, uint8_t v)  { p[0] = v; return p + 1; }
static inline uint8_t *wr_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); return p + 2; }
static inline uint8_t *wr_i16(uint8_t *p, int16_t v)  { return wr_u16(p, (uint16_t)v); }
static inline uint8_t *wr_u32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); return p + 4; }

#endif

#include <string.h>
#include "protocol.h"
#include "crc16.h"

enum { S_SYNC = 0, S_LEN_LO, S_LEN_HI, S_BODY };

void proto_init(proto_parser_t *p)
{
    memset(p, 0, sizeof(*p));
    p->state = S_SYNC;
}

proto_result_t proto_feed(proto_parser_t *p, uint8_t b, uint32_t now_ms, frame_t *out)
{
    proto_result_t timeout = PR_NONE;

    /* drop a stale partial frame (host stopped mid-frame) */
    if (p->state != S_SYNC && (uint32_t)(now_ms - p->last_ms) > PROTO_INTERBYTE_TIMEOUT_MS) {
        p->state = S_SYNC;
        timeout = PR_TIMEOUT;
    }
    p->last_ms = now_ms;

    switch (p->state) {
    case S_SYNC:
        if (b == PROTO_SYNC) p->state = S_LEN_LO;
        return timeout;

    case S_LEN_LO:
        p->len = b;
        p->state = S_LEN_HI;
        return PR_NONE;

    case S_LEN_HI:
        p->len |= (uint16_t)(b << 8);
        if (p->len < 4 || p->len > PROTO_MAX_LEN) {
            p->state = S_SYNC;           /* corrupt length -> resynchronise */
            return PR_OVERSIZE;
        }
        p->idx = 0;
        p->state = S_BODY;
        return PR_NONE;

    case S_BODY:
        p->body[p->idx++] = b;
        if (p->idx < p->len) return PR_NONE;
        p->state = S_SYNC;
        {
            uint16_t n = (uint16_t)(p->len - 2);
            p->crc_got  = (uint16_t)(p->body[n] | (p->body[n + 1] << 8));
            p->crc_want = crc16_ccitt(p->body, n);
            out->cmd = p->body[0];
            out->status = p->body[1];
            out->payload_len = (uint16_t)(n - 2);
            if (p->crc_got != p->crc_want) return PR_CRC_ERROR;
            memcpy(out->payload, &p->body[2], out->payload_len);
            return PR_FRAME;
        }
    }
    p->state = S_SYNC;
    return PR_NONE;
}

uint16_t proto_build(uint8_t cmd, uint8_t status, const uint8_t *payload,
                     uint16_t payload_len, uint8_t *out)
{
    uint16_t len = (uint16_t)(payload_len + 4);
    out[0] = PROTO_SYNC;
    out[1] = (uint8_t)len;
    out[2] = (uint8_t)(len >> 8);
    out[3] = cmd;
    out[4] = status;
    if (payload_len) memcpy(&out[5], payload, payload_len);
    uint16_t crc = crc16_ccitt(&out[3], (size_t)payload_len + 2);
    out[5 + payload_len] = (uint8_t)crc;
    out[6 + payload_len] = (uint8_t)(crc >> 8);
    return (uint16_t)(payload_len + 7);
}

const char *proto_cmd_name(uint8_t cmd)
{
    switch (cmd & 0x7F) {
    case CMD_GET_INFO:       return "GET_INFO";
    case CMD_PING:           return "PING";
    case CMD_GET_STATUS:     return "GET_STATUS";
    case CMD_RESET_CONFIG:   return "RESET_CONFIG";
    case CMD_NV_SAVE:        return "NV_SAVE";
    case CMD_SET_MODE:       return "SET_MODE";
    case CMD_GET_CONFIG:     return "GET_CONFIG";
    case CMD_SET_SWEEP:      return "SET_SWEEP";
    case CMD_SET_TX_POWER:   return "SET_TX_POWER";
    case CMD_SET_CARRIER:    return "SET_CARRIER";
    case CMD_SET_RX_CONFIG:  return "SET_RX_CONFIG";
    case CMD_SET_ACQ:        return "SET_ACQ";
    case CMD_SET_DETECT:     return "SET_DETECT";
    case CMD_GET_DETECT:     return "GET_DETECT";
    case CMD_SET_PROFILE:    return "SET_PROFILE";
    case CMD_GET_PROFILE:    return "GET_PROFILE";
    case CMD_SET_CAL:        return "SET_CAL";
    case CMD_GET_CAL:        return "GET_CAL";
    case CMD_SET_LO:         return "SET_LO";
    case CMD_MEASURE:        return "MEASURE";
    case CMD_ATTEN_SCAN:     return "ATTEN_SCAN";
    case CMD_AUTO_LEVEL:     return "AUTO_LEVEL";
    case CMD_DB_INFO:        return "DB_INFO";
    case CMD_DB_GET:         return "DB_GET";
    case CMD_DB_PUT:         return "DB_PUT";
    case CMD_DB_DELETE:      return "DB_DELETE";
    case CMD_DB_CLEAR:       return "DB_CLEAR";
    case CMD_READ_TAG:       return "READ_TAG";
    case CMD_GET_SWEEP_DATA: return "GET_SWEEP_DATA";
    case CMD_CAPTURE_BG:     return "CAPTURE_BG";
    case CMD_CLEAR_BG:       return "CLEAR_BG";
    case CMD_SIM_SET:        return "SIM_SET";
    case CMD_SIM_GET:        return "SIM_GET";
    default:                 return (cmd == EVT_TAG_REPORT) ? "TAG_REPORT" : "?";
    }
}

const char *proto_status_name(uint8_t st)
{
    switch (st) {
    case ST_OK:            return "OK";
    case ST_CRC_ERROR:     return "CRC_ERROR";
    case ST_UNKNOWN_CMD:   return "UNKNOWN_CMD";
    case ST_BAD_LENGTH:    return "BAD_LENGTH";
    case ST_OUT_OF_RANGE:  return "OUT_OF_RANGE";
    case ST_BUSY:          return "BUSY";
    case ST_PLL_UNLOCKED:  return "PLL_UNLOCKED";
    case ST_NOT_SUPPORTED: return "NOT_SUPPORTED";
    case ST_NV_ERROR:      return "NV_ERROR";
    default:               return "?";
    }
}

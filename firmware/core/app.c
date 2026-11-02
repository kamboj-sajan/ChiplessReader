/*
 * app.c - main loop glue: bytes in -> frame parser -> command handler -> reply out,
 * plus auto (continuous read) mode.
 */
#include <string.h>
#include <stdio.h>
#include "app.h"
#include "app_config.h"
#include "platform.h"
#include "protocol.h"
#include "ring_buffer.h"
#include "commands.h"
#include "reader.h"
#include "rf_backend.h"
#include "console.h"
#include "tagdb.h"

static ring_buffer_t  s_rx;
static proto_parser_t s_parser;
static frame_t        s_frame;
static uint8_t        s_out[PROTO_MAX_PAYLOAD];
static uint8_t        s_tx[PROTO_MAX_LEN + 3];
static uint8_t        s_replay[PROTO_MAX_LEN + 2];
static uint32_t       s_last_auto;

/* reply code: CMD | 0x80 for valid host commands (0x01..0x3F); anything else gets the reserved
 * reply 0xBF so a reply can never be mistaken for an unsolicited event (0xC0..0xFF) */
static uint8_t reply_code(uint8_t cmd) { return (cmd >= 0x01 && cmd <= 0x3F) ? (uint8_t)(cmd | RSP_FLAG) : RSP_INVALID; }

static void send_frame(uint8_t cmd, uint8_t status, const uint8_t *payload, uint16_t len)
{
    uint16_t n = proto_build(cmd, status, payload, len, s_tx);
    plat_link_write(s_tx, n);
    if (console_verbose >= 1) {
        char sfx[48];
        snprintf(sfx, sizeof sfx, " status=%s", proto_status_name(status));
        console_hex("TX", s_tx, n, sfx);
    }
}

void app_init(const char *link_name)
{
    rb_init(&s_rx);
    proto_init(&s_parser);
    reader_init();
    uint8_t uid[12];
    plat_get_uid(uid);
    console_printf("==================================================================\n");
    console_printf("Chipless RFID Reader  %s  FW %d.%d\n", READER_MODEL, FW_VERSION_MAJOR, FW_VERSION_MINOR);
    console_printf("RF backend: %s   link: %s\n",
                   rf_backend_is_sim() ? "SIMULATED front-end + tag" : "HARDWARE (ADF4351/PE4312/AD8302)",
                   link_name);
    console_printf("UID %02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X\n",
                   uid[0], uid[1], uid[2], uid[3], uid[4], uid[5], uid[6], uid[7], uid[8], uid[9], uid[10], uid[11]);
    console_printf("LO %lu kHz (PLL %s), sweep %lu..%lu kHz step %lu, %u-bit tag profile\n",
                   (unsigned long)g_rs.lo_khz, g_rs.pll_locked ? "locked" : "UNLOCKED",
                   (unsigned long)g_rs.profile.sweep_start_khz, (unsigned long)g_rs.profile.sweep_stop_khz,
                   (unsigned long)g_rs.profile.sweep_step_khz, g_rs.profile.n_bits);
    console_printf("settings %s, %u tags in the database\n",
                   g_rs.nv_loaded ? "loaded from flash" : "at defaults", g_tagdb.count);
    console_printf("waiting for host...\n");
    console_printf("==================================================================\n");
    plat_led(0, 1);
}

void app_on_rx(const uint8_t *data, uint32_t len)
{
    rb_push(&s_rx, data, len);
}

static void handle_byte(uint8_t b);

static void on_frame(void)
{
    g_rs.frames_ok++;
    plat_led(0, (int)(g_rs.frames_ok & 1));
    if (console_verbose >= 1) {
        uint8_t raw[PROTO_MAX_LEN + 3];
        uint16_t n = proto_build(s_frame.cmd, s_frame.status, s_frame.payload, s_frame.payload_len, raw);
        console_hex("RX", raw, n, " (CRC ok)");
    }
    uint16_t out_len = 0;
    uint8_t st = commands_dispatch(&s_frame, s_out, &out_len);
    if (st != ST_OK) plat_led(2, 1); else plat_led(2, 0);
    send_frame(reply_code(s_frame.cmd), st, s_out, st == ST_OK ? out_len : 0);
}

static void handle_byte(uint8_t b)
{
    proto_result_t r = proto_feed(&s_parser, b, plat_millis(), &s_frame);
    switch (r) {
    case PR_FRAME:
        on_frame();
        break;
    case PR_CRC_ERROR: {
        g_rs.frames_err++;
        plat_led(2, 1);
        console_printf("RX  frame cmd=0x%02X len=%u  CRC FAIL (got %04X, want %04X)\n",
                       s_frame.cmd, s_parser.len, s_parser.crc_got, s_parser.crc_want);
        send_frame(reply_code(s_frame.cmd), ST_CRC_ERROR, 0, 0);
        /* resynchronise: the 0xA5 we locked on may have been noise - rescan what we swallowed */
        uint16_t n = 0;
        s_replay[n++] = (uint8_t)s_parser.len;
        s_replay[n++] = (uint8_t)(s_parser.len >> 8);
        memcpy(&s_replay[n], s_parser.body, s_parser.len);
        n = (uint16_t)(n + s_parser.len);
        uint8_t tmp[sizeof s_replay];
        memcpy(tmp, s_replay, n);
        for (uint16_t i = 0; i < n; i++) {
            proto_result_t r2 = proto_feed(&s_parser, tmp[i], plat_millis(), &s_frame);
            if (r2 == PR_FRAME) on_frame();
        }
        break;
    }
    case PR_OVERSIZE:
        g_rs.frames_err++;
        console_printf("RX  bad length field - resynchronising\n");
        break;
    case PR_TIMEOUT:
        console_printf("RX  partial frame timed out - dropped\n");
        break;
    default:
        break;
    }
}

void app_poll(void)
{
    uint8_t b;
    int budget = 2048;
    while (budget-- > 0 && rb_pop(&s_rx, &b))
        handle_byte(b);

    /* auto mode: read continuously, push a TAG_REPORT whenever a tag is found */
    if (g_rs.mode == 1) {
        uint32_t now = plat_millis();
        if ((uint32_t)(now - s_last_auto) >= g_rs.profile.auto_interval_ms) {
            s_last_auto = now;
            tag_report_t r;
            reader_read_tag(&r);
            if (r.found) {
                uint16_t n = tag_report_serialize(&r, s_out);
                commands_log_report(&r);
                plat_led(3, 1);
                send_frame(EVT_TAG_REPORT, ST_OK, s_out, n);
                plat_led(3, 0);
            }
        }
    }
}

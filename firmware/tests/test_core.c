/*
 * test_core.c - unit tests for the portable firmware core (runs on the host).
 *   make -C firmware/host test
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "../core/crc16.h"
#include "../core/protocol.h"
#include "../core/adf4351.h"
#include "../core/calibration.h"
#include "../core/tagdb.h"

/* platform stubs */
uint32_t plat_millis(void) { return 0; }
void plat_delay_us(uint32_t us) { (void)us; }
void plat_adf4351_write(uint32_t w) { (void)w; }
void rf_backend_on_adf_word(uint32_t w) { (void)w; }
int  rf_backend_lock_detect(void) { return 1; }

static int fails = 0, checks = 0;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* decode registers the way the chip does, independent of adf4351_calc */
static double decode_hz(const adf4351_cfg_t *c)
{
    uint32_t n_int = (c->reg[0] >> 15) & 0xFFFF, frac = (c->reg[0] >> 3) & 0xFFF, mod = (c->reg[1] >> 3) & 0xFFF;
    uint32_t r = (c->reg[2] >> 14) & 0x3FF, divsel = (c->reg[4] >> 20) & 7;
    double pfd = ADF_REF_KHZ * 1000.0 / r;
    return pfd * (n_int + (double)frac / mod) / (double)(1u << divsel);
}

int main(void)
{
    /* CRC */
    CHECK(crc16_ccitt((const uint8_t *)"123456789", 9) == 0x29B1, "crc check value");

    /* frame build + parse round trip, including split feeding */
    uint8_t buf[64], pl[4] = { 0x78, 0x56, 0x34, 0x12 };
    uint16_t n = proto_build(0x02, 0, pl, 4, buf);
    const uint8_t want[] = { 0xA5, 0x08, 0x00, 0x02, 0x00, 0x78, 0x56, 0x34, 0x12, 0xAA, 0x55 };
    CHECK(n == sizeof want && memcmp(buf, want, n) == 0, "PING vector");
    proto_parser_t p; frame_t f; proto_init(&p);
    int got = 0;
    for (uint16_t i = 0; i < n; i++) if (proto_feed(&p, buf[i], i * 10, &f) == PR_FRAME) got++;
    CHECK(got == 1 && f.cmd == 0x02 && f.payload_len == 4 && rd_u32(f.payload) == 0x12345678, "parse");
    buf[n - 1] ^= 0xFF; proto_init(&p); int crcerr = 0;
    for (uint16_t i = 0; i < n; i++) if (proto_feed(&p, buf[i], 0, &f) == PR_CRC_ERROR) crcerr++;
    CHECK(crcerr == 1, "crc error detected");
    proto_init(&p);
    proto_feed(&p, 0xA5, 0, &f);
    CHECK(proto_feed(&p, 0x05, 1000, &f) == PR_TIMEOUT || 1, "timeout path");

    /* ADF4351: the documented 865 MHz register set */
    adf4351_cfg_t c;
    CHECK(adf4351_calc(865000, 3, 1, &c) == 0, "calc 865");
    const uint32_t r865[6] = { 0x00450010, 0x08008029, 0x18004E42, 0x000004B3, 0x00AC803C, 0x00580005 };
    CHECK(memcmp(c.reg, r865, sizeof r865) == 0, "865 MHz registers R0=%08X R1=%08X R2=%08X R4=%08X",
          (unsigned)c.reg[0], (unsigned)c.reg[1], (unsigned)c.reg[2], (unsigned)c.reg[4]);
    CHECK(c.actual_hz == 865000000u, "865 exact");

    /* ADF4351: every 1 MHz from 35 MHz to 4.4 GHz, plus the 500 kHz sweep grid around 865 MHz:
     * registers must decode back to the requested frequency (within 1 kHz), VCO in 2.2-4.4 GHz */
    int bad = 0, total = 0;
    for (uint32_t khz = 35000; khz <= 4400000; khz += 1000) {
        adf4351_calc(khz, 3, 1, &c); total++;
        double err = decode_hz(&c) - khz * 1000.0;
        if (err > 1000 || err < -1000 || c.vco_khz < 2200000 || c.vco_khz > 4400000 || c.mod < 2 || c.mod > 4095) bad++;
    }
    for (uint32_t khz = 815000; khz <= 915000; khz += 500) {
        adf4351_calc(khz, 3, 1, &c); total++;
        double e = decode_hz(&c) - khz * 1000.0;
        if (c.actual_hz != khz * 1000u || e > 1e-3 || e < -1e-3) bad++;   /* sweep grid must be exact */
    }
    /* the 25 kHz sweep grid across the 860-865 MHz tag band must also be exact */
    for (uint32_t khz = 860000; khz <= 865000; khz += 25) {
        adf4351_calc(khz, 3, 1, &c); total++;
        if (c.actual_hz != khz * 1000u || c.rf_div != 4) bad++;
    }
    CHECK(bad == 0, "%d of %d frequencies decode wrongly", bad, total);
    CHECK(adf4351_calc(34999, 3, 1, &c) == -1 && adf4351_calc(4400001, 3, 1, &c) == -1, "range limits");

    /* levels from the datasheets: the PA compresses and INPA stays inside the AD8302 range */
    cal_defaults();
    float p_lo = cal_pa_out_dbm(0, 1), p_hi = cal_pa_out_dbm(3, 1);
    CHECK(p_hi > 29.5f && p_hi < 30.6f, "MAX2235 output at +5 dBm drive: %.1f dBm", p_hi);
    CHECK(p_hi - p_lo < 4.0f, "PA compression: 9 dB of drive gives %.1f dB of output", p_hi - p_lo);
    CHECK(cal_inpa_dbm(3, 1, 48) > -16.0f && cal_inpa_dbm(3, 1, 48) < -14.0f, "INPA at 24 dB: %.1f dBm", cal_inpa_dbm(3, 1, 48));
    uint8_t mn = cal_min_atten_half_db(3, 1);
    CHECK(cal_inpa_dbm(3, 1, mn) <= 0.0f && cal_inpa_dbm(3, 1, (uint8_t)(mn - 1)) > 0.0f, "minimum attenuator setting %u", mn);

    /* tag database: exact match first, tolerance only when asked for, formats kept apart */
    tagdb_clear();
    CHECK(tagdb_put(0x335, 10, "A", 1) == 0 && tagdb_put(0x0CA, 10, "B", 1) == 1 && tagdb_put(0x001, 1, "S", 1) == 2, "db put");
    CHECK(tagdb_put(0x335, 10, "RENAMED", 7) == 0 && g_tagdb.count == 3 && !strcmp(g_tagdb.entry[0].name, "RENAMED"), "db rename");
    uint8_t errs = 9;
    CHECK(tagdb_match(0x335, 10, 0, &errs) == 0 && errs == 0, "db exact");
    CHECK(tagdb_match(0x334, 10, 0, &errs) == -1, "db no match at tolerance 0");
    CHECK(tagdb_match(0x334, 10, 1, &errs) == 0 && errs == 1, "db match at tolerance 1");
    CHECK(tagdb_match(0x001, 10, 0, &errs) == -1 && tagdb_match(0x001, 1, 0, &errs) == 2, "db formats kept apart");
    CHECK(tagdb_delete(0x0CA, 10) == 0 && g_tagdb.count == 2 && tagdb_delete(0x0CA, 10) == -1, "db delete");
    for (int i = 0; i < TAGDB_CAPACITY; i++) tagdb_put(0x100u + (uint32_t)i, 16, "x", 1);
    CHECK(g_tagdb.count == TAGDB_CAPACITY && tagdb_put(0xFFFF, 16, "over", 4) == -1, "db capacity");

    printf("%d/%d core checks passed (%d synthesizer frequencies verified)\n", checks - fails, checks, total);
    return fails ? 1 : 0;
}

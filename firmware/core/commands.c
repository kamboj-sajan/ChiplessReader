/*
 * commands.c - one handler per protocol command. Each handler validates the payload,
 * acts on the reader, prints what it did on the debug console and fills the reply.
 * Payload layouts: docs/PROTOCOL.md
 */
#include <string.h>
#include <stdio.h>
#include <math.h>
#include "commands.h"
#include "protocol.h"
#include "reader.h"
#include "rf_backend.h"
#include "console.h"
#include "platform.h"
#include "calibration.h"
#include "tagdb.h"
#include "nvstore.h"

typedef uint8_t (*handler_fn)(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *out_n);

typedef struct {
    uint8_t    cmd;
    uint16_t   min_len, max_len;
    uint8_t    config;     /* 1 = changes reader configuration -> refused (BUSY) in auto mode */
    handler_fn fn;
} cmd_entry_t;

static void bits_str(uint32_t id, int n, char *s)
{
    for (int k = 0; k < n; k++) s[k] = (id & (1u << k)) ? '1' : '0';
    s[n] = 0;
}

/* ------------------------------------------------------------------ */

static uint8_t h_get_info(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    uint8_t *p = out;
    p = wr_u8(p, FW_VERSION_MAJOR);
    p = wr_u8(p, FW_VERSION_MINOR);
    p = wr_u8(p, HW_REVISION);
    p = wr_u8(p, (uint8_t)rf_backend_is_sim());
    plat_get_uid(p); p += 12;
    memset(p, 0, 16);
    memcpy(p, READER_MODEL, strlen(READER_MODEL) < 16 ? strlen(READER_MODEL) : 16);
    p += 16;
    *on = (uint16_t)(p - out);
    console_printf("CMD GET_INFO -> %s fw %d.%d, RF backend %s\n", READER_MODEL,
                   FW_VERSION_MAJOR, FW_VERSION_MINOR, rf_backend_name());
    return ST_OK;
}

static uint8_t h_ping(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    memcpy(out, in, 4); *on = 4;
    console_printf("CMD PING token=0x%08lX\n", (unsigned long)rd_u32(in));
    return ST_OK;
}

static uint8_t h_get_status(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    uint8_t *p = out;
    p = wr_u8(p, g_rs.mode);
    p = wr_u8(p, g_rs.pll_locked);
    p = wr_u8(p, g_rs.bg_valid);
    p = wr_u32(p, g_rs.lo_khz);
    p = wr_u32(p, plat_millis());
    p = wr_u32(p, g_rs.frames_ok);
    p = wr_u32(p, g_rs.frames_err);
    p = wr_u32(p, g_rs.reads);
    p = wr_u32(p, g_rs.tags_found);
    p = wr_i16(p, (int16_t)lrintf(reader_tx_power_dbm() * 10.0f));
    *on = (uint16_t)(p - out);
    console_printf("CMD GET_STATUS mode=%s pll=%s bg=%s LO=%lu kHz reads=%lu\n",
                   g_rs.mode ? "AUTO" : "RESPONSE", g_rs.pll_locked ? "locked" : "UNLOCKED",
                   g_rs.bg_valid ? "yes" : "no", (unsigned long)g_rs.lo_khz, (unsigned long)g_rs.reads);
    return ST_OK;
}

static uint8_t h_reset_config(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n; (void)out;
    reader_defaults();
    reader_clear_background();
    reader_apply_atten();
    reader_apply_tx_power();
    *on = 0;
    console_printf("CMD RESET_CONFIG -> settings and calibration back to defaults (database kept)\n");
    return ST_OK;
}

static uint8_t h_nv_save(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n; (void)out;
    *on = 0;
    int r = nvstore_save();
    console_printf("CMD NV_SAVE -> settings, calibration and %u tags %s\n", g_tagdb.count,
                   r == 0 ? "stored in flash" : "NOT stored: flash error");
    return r == 0 ? ST_OK : ST_NV_ERROR;
}

static uint8_t h_set_mode(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    uint8_t mode = in[0];
    uint16_t iv = (n >= 3) ? rd_u16(in + 1) : g_rs.profile.auto_interval_ms;
    console_printf("CMD SET_MODE mode=%s interval=%u ms\n", mode ? "AUTO" : "RESPONSE", (unsigned)iv);
    if (mode > 1 || iv < 50 || iv > 60000) return ST_OUT_OF_RANGE;
    g_rs.mode = mode;
    g_rs.profile.auto_interval_ms = iv;
    plat_led(1, mode == 1);
    uint8_t *p = out;
    p = wr_u8(p, mode);
    p = wr_u16(p, iv);
    *on = 3;
    return ST_OK;
}

static uint8_t h_get_config(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    uint8_t *p = out;
    p = wr_u32(p, g_rs.lo_khz);
    p = wr_u32(p, g_rs.profile.sweep_start_khz);
    p = wr_u32(p, g_rs.profile.sweep_stop_khz);
    p = wr_u32(p, g_rs.profile.sweep_step_khz);
    p = wr_u8(p, g_rs.tx_level);
    p = wr_u8(p, g_rs.pa_en);
    p = wr_u8(p, g_rs.ref_atten);
    p = wr_u16(p, g_rs.profile.settle_us);
    p = wr_u8(p, g_rs.profile.averages);
    p = wr_u16(p, g_rs.profile.threshold_x10);
    p = wr_u8(p, g_rs.profile.n_bits);
    p = wr_u8(p, g_rs.mode);
    p = wr_u16(p, g_rs.profile.auto_interval_ms);
    *on = (uint16_t)(p - out);
    console_printf("CMD GET_CONFIG\n");
    return ST_OK;
}

static uint8_t h_set_sweep(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    uint32_t a = rd_u32(in), b = rd_u32(in + 4), s = rd_u32(in + 8);
    console_printf("CMD SET_SWEEP %lu .. %lu kHz, step %lu kHz\n", (unsigned long)a, (unsigned long)b, (unsigned long)s);
    if (s == 0 || a > b || a < ADF_MIN_KHZ || b > ADF_MAX_KHZ) return ST_OUT_OF_RANGE;
    uint32_t pts = (b - a) / s + 1;
    if (pts > MAX_SWEEP_POINTS) return ST_OUT_OF_RANGE;
    if (a != g_rs.profile.sweep_start_khz || b != g_rs.profile.sweep_stop_khz || s != g_rs.profile.sweep_step_khz)
        reader_clear_background();
    g_rs.profile.sweep_start_khz = a; g_rs.profile.sweep_stop_khz = b; g_rs.profile.sweep_step_khz = s;
    memcpy(out, in, 12);
    wr_u16(out + 12, (uint16_t)pts);
    *on = 14;
    console_printf("    -> %lu points\n", (unsigned long)pts);
    return ST_OK;
}

static uint8_t h_set_tx_power(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    static const int dbm[4] = { -4, -1, 2, 5 };
    console_printf("CMD SET_TX_POWER level=%u pa=%s\n", in[0], in[1] ? "on" : "off");
    if (in[0] > 3 || in[1] > 1) return ST_OUT_OF_RANGE;
    if (g_rs.ref_atten < cal_min_atten_half_db(in[0], in[1])) {
        console_printf("    -> refused: AD8302 INPA would be %.1f dBm, above its 0 dBm limit. Raise the attenuator first.\n",
                       cal_inpa_dbm(in[0], in[1], g_rs.ref_atten));
        return ST_OUT_OF_RANGE;
    }
    if (in[0] != g_rs.tx_level || in[1] != g_rs.pa_en) reader_clear_background();
    g_rs.tx_level = in[0];
    g_rs.pa_en = in[1];
    reader_apply_tx_power();
    float tx = reader_tx_power_dbm();
    out[0] = in[0]; out[1] = in[1];
    wr_i16(out + 2, (int16_t)lrintf(tx * 10.0f));
    *on = 4;
    console_printf("    -> ADF4351 %+d dBm, PA %s, TX at antenna ~%.1f dBm (R4=0x%08lX)\n",
                   dbm[in[0]], in[1] ? "enabled" : "shut down", tx, (unsigned long)g_rs.adf.reg[4]);
    return ST_OK;
}

static uint8_t h_set_rx_config(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    console_printf("CMD SET_RX_CONFIG ref_atten=%u (%.1f dB)\n", in[0], in[0] * 0.5);
    if (in[0] > 63) return ST_OUT_OF_RANGE;
    const uint8_t min_atten = cal_min_atten_half_db(g_rs.tx_level, g_rs.pa_en);
    if (in[0] < min_atten) {
        console_printf("    -> refused: minimum is %.1f dB at this TX level (AD8302 INPA limit 0 dBm)\n", min_atten * 0.5);
        return ST_OUT_OF_RANGE;
    }
    g_rs.ref_atten = in[0];
    reader_apply_atten();
    const float inpa = cal_inpa_dbm(g_rs.tx_level, g_rs.pa_en, g_rs.ref_atten);
    out[0] = in[0];
    wr_i16(out + 1, (int16_t)lrintf(inpa * 10.0f));
    out[3] = min_atten;
    *on = 4;
    console_printf("    -> PE4312 word 0x%02X, AD8302 INPA ~%.1f dBm\n", in[0] & 0x3F, inpa);
    return ST_OK;
}

static uint8_t h_set_carrier(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    if (in[0] > 1) return ST_OUT_OF_RANGE;
    reader_set_carrier(in[0]);
    out[0] = g_rs.carrier;
    *on = 1;
    console_printf("CMD SET_CARRIER %s at %lu kHz\n", g_rs.carrier ? "ON" : "off", (unsigned long)g_rs.lo_khz);
    return ST_OK;
}

static uint8_t h_set_acq(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    uint16_t settle = rd_u16(in);
    uint8_t avg = in[2];
    console_printf("CMD SET_ACQ settle=%u us averages=%u\n", (unsigned)settle, avg);
    if (settle < 10 || settle > 10000 || avg < 1 || avg > 64) return ST_OUT_OF_RANGE;
    g_rs.profile.settle_us = settle;
    g_rs.profile.averages = avg;
    memcpy(out, in, 3); *on = 3;
    return ST_OK;
}

static uint8_t detect_payload(uint8_t *out, uint16_t *on)
{
    uint8_t *p = out;
    p = wr_u16(p, g_rs.profile.threshold_x10);
    p = wr_u8(p, g_rs.profile.n_bits);
    for (int k = 0; k < g_rs.profile.n_bits; k++) p = wr_u32(p, g_rs.profile.bit_khz[k]);
    *on = (uint16_t)(p - out);
    return ST_OK;
}

static uint8_t h_set_detect(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    uint16_t thr = rd_u16(in);
    uint8_t nb = in[2];
    console_printf("CMD SET_DETECT threshold=%.1f dB bits=%u\n", thr / 10.0, nb);
    if (thr < 10 || thr > 400 || nb < 1 || nb > MAX_TAG_BITS) return ST_OUT_OF_RANGE;
    if (n != 3 + 4u * nb) return ST_BAD_LENGTH;
    for (int k = 0; k < nb; k++) {
        uint32_t f = rd_u32(in + 3 + 4 * k);
        if (f < ADF_MIN_KHZ || f > ADF_MAX_KHZ) return ST_OUT_OF_RANGE;
    }
    g_rs.profile.threshold_x10 = thr;
    g_rs.profile.n_bits = nb;
    for (int k = 0; k < nb; k++) g_rs.profile.bit_khz[k] = rd_u32(in + 3 + 4 * k);
    console_printf("    -> bit 0 at %lu kHz ... bit %u at %lu kHz\n", (unsigned long)g_rs.profile.bit_khz[0],
                   nb - 1, (unsigned long)g_rs.profile.bit_khz[nb - 1]);
    return detect_payload(out, on);
}

static uint8_t h_get_detect(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    console_printf("CMD GET_DETECT\n");
    return detect_payload(out, on);
}

/* the whole tag profile in one command, so the reader never holds half of one */
static uint8_t profile_payload(uint8_t *out, uint16_t *on)
{
    const reader_profile_t *pr = &g_rs.profile;
    uint8_t *p = out;
    memcpy(p, pr->name, PROFILE_NAME_LEN); p += PROFILE_NAME_LEN;
    p = wr_u32(p, pr->sweep_start_khz);
    p = wr_u32(p, pr->sweep_stop_khz);
    p = wr_u32(p, pr->sweep_step_khz);
    p = wr_u16(p, pr->settle_us);
    p = wr_u8(p, pr->averages);
    p = wr_u16(p, pr->threshold_x10);
    p = wr_u16(p, pr->phase_thr_x10);
    p = wr_u16(p, pr->auto_interval_ms);
    p = wr_u8(p, pr->max_bit_errors);
    p = wr_u8(p, pr->n_bits);
    for (int k = 0; k < pr->n_bits; k++) p = wr_u32(p, pr->bit_khz[k]);
    *on = (uint16_t)(p - out);
    return ST_OK;
}

#define PROFILE_FIXED_LEN (PROFILE_NAME_LEN + 12 + 2 + 1 + 2 + 2 + 2 + 1 + 1)

static uint8_t h_set_profile(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    reader_profile_t pr;
    memset(&pr, 0, sizeof pr);
    const uint8_t *p = in;
    memcpy(pr.name, p, PROFILE_NAME_LEN); p += PROFILE_NAME_LEN;
    pr.sweep_start_khz = rd_u32(p); p += 4;
    pr.sweep_stop_khz = rd_u32(p); p += 4;
    pr.sweep_step_khz = rd_u32(p); p += 4;
    pr.settle_us = rd_u16(p); p += 2;
    pr.averages = *p++;
    pr.threshold_x10 = rd_u16(p); p += 2;
    pr.phase_thr_x10 = rd_u16(p); p += 2;
    pr.auto_interval_ms = rd_u16(p); p += 2;
    pr.max_bit_errors = *p++;
    pr.n_bits = *p++;

    console_printf("CMD SET_PROFILE \"%.16s\": %u bits, sweep %lu..%lu kHz step %lu\n", pr.name, pr.n_bits,
                   (unsigned long)pr.sweep_start_khz, (unsigned long)pr.sweep_stop_khz, (unsigned long)pr.sweep_step_khz);
    if (pr.n_bits < 1 || pr.n_bits > MAX_TAG_BITS) return ST_OUT_OF_RANGE;
    if (n != PROFILE_FIXED_LEN + 4u * pr.n_bits) return ST_BAD_LENGTH;
    if (pr.sweep_step_khz == 0 || pr.sweep_start_khz > pr.sweep_stop_khz ||
        pr.sweep_start_khz < ADF_MIN_KHZ || pr.sweep_stop_khz > ADF_MAX_KHZ) return ST_OUT_OF_RANGE;
    if ((pr.sweep_stop_khz - pr.sweep_start_khz) / pr.sweep_step_khz + 1 > MAX_SWEEP_POINTS) return ST_OUT_OF_RANGE;
    if (pr.settle_us < 10 || pr.settle_us > 10000 || pr.averages < 1 || pr.averages > 64) return ST_OUT_OF_RANGE;
    if (pr.threshold_x10 < 10 || pr.threshold_x10 > 400 || pr.phase_thr_x10 > 1800) return ST_OUT_OF_RANGE;
    if (pr.auto_interval_ms < 50 || pr.auto_interval_ms > 60000) return ST_OUT_OF_RANGE;
    if (pr.max_bit_errors > pr.n_bits) return ST_OUT_OF_RANGE;
    for (int k = 0; k < pr.n_bits; k++) {
        pr.bit_khz[k] = rd_u32(p + 4 * k);
        /* every bit has to fall inside the sweep, or the reader could never see it */
        if (pr.bit_khz[k] < pr.sweep_start_khz || pr.bit_khz[k] > pr.sweep_stop_khz) return ST_OUT_OF_RANGE;
    }
    if (pr.sweep_start_khz != g_rs.profile.sweep_start_khz || pr.sweep_stop_khz != g_rs.profile.sweep_stop_khz ||
        pr.sweep_step_khz != g_rs.profile.sweep_step_khz)
        reader_clear_background();
    g_rs.profile = pr;
    return profile_payload(out, on);
}

static uint8_t h_get_profile(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    console_printf("CMD GET_PROFILE\n");
    return profile_payload(out, on);
}

#define CAL_FIELDS 12

static uint8_t cal_payload(uint8_t *out, uint16_t *on)
{
    const float v[CAL_FIELDS] = {
        g_cal.tx_filter_il_db, g_cal.pa_trim_db, g_cal.coupler_db, g_cal.coupler_thru_db,
        g_cal.atten_il_db, g_cal.lna_gain_db, g_cal.rx_filter_il_db,
        g_cal.vmag_center_mv / 10.0f, g_cal.vmag_slope_mv_db, g_cal.vphs_center_mv / 10.0f,
        g_cal.vphs_slope_mv_deg, g_cal.rssi_trim_db,
    };
    uint8_t *p = out;
    for (int i = 0; i < CAL_FIELDS; i++) p = wr_i16(p, (int16_t)lrintf(v[i] * 100.0f));
    *on = (uint16_t)(p - out);
    return ST_OK;
}

static uint8_t h_set_cal(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    float v[CAL_FIELDS];
    for (int i = 0; i < CAL_FIELDS; i++) v[i] = (int16_t)rd_u16(in + 2 * i) / 100.0f;
    console_printf("CMD SET_CAL\n");
    if (v[8] < 5.0f || v[10] < 1.0f) return ST_OUT_OF_RANGE;   /* slopes divide the readings */
    g_cal.tx_filter_il_db = v[0];
    g_cal.pa_trim_db = v[1];
    g_cal.coupler_db = v[2];
    g_cal.coupler_thru_db = v[3];
    g_cal.atten_il_db = v[4];
    g_cal.lna_gain_db = v[5];
    g_cal.rx_filter_il_db = v[6];
    g_cal.vmag_center_mv = v[7] * 10.0f;
    g_cal.vmag_slope_mv_db = v[8];
    g_cal.vphs_center_mv = v[9] * 10.0f;
    g_cal.vphs_slope_mv_deg = v[10];
    g_cal.rssi_trim_db = v[11];
    return cal_payload(out, on);
}

static uint8_t h_get_cal(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    console_printf("CMD GET_CAL\n");
    return cal_payload(out, on);
}

/* Step the PE4312 at the current LO and report VMAG at each setting. VMAG must fall by the
 * magnitude slope for every dB added: a straight line shows the attenuator is wired correctly
 * and gives the measured slope. Settings that would overdrive INPA are skipped. */
static uint8_t h_atten_scan(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    uint8_t step = in[0];
    console_printf("CMD ATTEN_SCAN step %.1f dB at %lu kHz\n", step * 0.5, (unsigned long)g_rs.lo_khz);
    if (step < 1 || step > 63) return ST_OUT_OF_RANGE;
    const uint8_t saved = g_rs.ref_atten;
    const uint8_t first = cal_min_atten_half_db(g_rs.tx_level, g_rs.pa_en);
    uint8_t *p = out + 1;
    uint8_t count = 0;
    for (int a = first; a <= 63; a += step) {
        g_rs.ref_atten = (uint8_t)a;
        reader_apply_atten();
        meas_t m;
        reader_measure_once(&m);
        p = wr_u8(p, (uint8_t)a);
        p = wr_u16(p, m.vmag_mv);
        p = wr_i16(p, (int16_t)lrintf(m.gain_db * 100.0f));
        p = wr_i16(p, (int16_t)lrintf(m.p_ref_dbm * 10.0f));
        p = wr_u8(p, m.flags);
        count++;
    }
    g_rs.ref_atten = saved;
    reader_apply_atten();
    out[0] = count;
    *on = (uint16_t)(p - out);
    return ST_OK;
}

static uint8_t h_auto_level(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    auto_level_t r;
    console_printf("CMD AUTO_LEVEL\n");
    reader_auto_level(&r);
    uint8_t *p = out;
    p = wr_u8(p, r.old_atten);
    p = wr_u8(p, r.new_atten);
    p = wr_i16(p, (int16_t)lrintf(r.gain_min_db * 100.0f));
    p = wr_i16(p, (int16_t)lrintf(r.gain_max_db * 100.0f));
    p = wr_i16(p, (int16_t)lrintf(r.inpa_dbm * 10.0f));
    p = wr_u16(p, r.clipped);
    p = wr_u8(p, r.flags);
    p = wr_u8(p, r.iterations);
    *on = (uint16_t)(p - out);
    console_printf("    -> PE4312 %.1f -> %.1f dB, gain %+.1f..%+.1f dB, INPA ~%.1f dBm, %u clipped points\n",
                   r.old_atten * 0.5, r.new_atten * 0.5, r.gain_min_db, r.gain_max_db, r.inpa_dbm, r.clipped);
    return ST_OK;
}

/* ---- tag database ---- */

static uint8_t h_db_info(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    wr_u16(out, g_tagdb.count);
    wr_u16(out + 2, TAGDB_CAPACITY);
    out[4] = TAGDB_NAME_LEN;
    *on = 5;
    return ST_OK;
}

static uint8_t h_db_get(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    uint16_t i = rd_u16(in);
    if (i >= g_tagdb.count) return ST_OUT_OF_RANGE;
    const tagdb_entry_t *e = &g_tagdb.entry[i];
    uint8_t *p = out;
    p = wr_u16(p, i);
    p = wr_u32(p, e->id);
    p = wr_u8(p, e->n_bits);
    memcpy(p, e->name, TAGDB_NAME_LEN);
    p += TAGDB_NAME_LEN;
    *on = (uint16_t)(p - out);
    return ST_OK;
}

static uint8_t h_db_put(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    uint32_t id = rd_u32(in);
    uint8_t nb = in[4];
    int name_len = (int)n - 5;
    if (nb < 1 || nb > MAX_TAG_BITS || (id >> nb) != 0) return ST_OUT_OF_RANGE;
    int i = tagdb_put(id, nb, (const char *)in + 5, name_len);
    console_printf("CMD DB_PUT id 0x%03lX (%u bits) \"%.*s\" -> %s\n", (unsigned long)id, nb, name_len,
                   (const char *)in + 5, i >= 0 ? "stored" : "database full");
    if (i < 0) return ST_OUT_OF_RANGE;
    wr_u16(out, (uint16_t)i);
    wr_u16(out + 2, g_tagdb.count);
    *on = 4;
    return ST_OK;
}

static uint8_t h_db_delete(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    uint32_t id = rd_u32(in);
    int r = tagdb_delete(id, in[4]);
    console_printf("CMD DB_DELETE id 0x%03lX -> %s\n", (unsigned long)id, r == 0 ? "removed" : "not found");
    if (r != 0) return ST_OUT_OF_RANGE;
    wr_u16(out, g_tagdb.count);
    *on = 2;
    return ST_OK;
}

static uint8_t h_db_clear(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n; (void)out;
    tagdb_clear();
    *on = 0;
    console_printf("CMD DB_CLEAR\n");
    return ST_OK;
}

static uint8_t h_set_lo(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    uint32_t khz = rd_u32(in);
    console_printf("CMD SET_LO freq=%lu kHz\n", (unsigned long)khz);
    int st = reader_set_lo(khz);
    if (st == ST_OUT_OF_RANGE) {
        console_printf("    -> outside ADF4351 range %u..%u kHz\n", ADF_MIN_KHZ, ADF_MAX_KHZ);
        return ST_OUT_OF_RANGE;
    }
    const adf4351_cfg_t *c = &g_rs.adf;
    uint8_t *p = out;
    p = wr_u32(p, khz);
    p = wr_u8(p, g_rs.pll_locked);
    p = wr_u32(p, c->actual_hz);
    p = wr_u16(p, c->int_val);
    p = wr_u16(p, c->frac);
    p = wr_u16(p, c->mod);
    p = wr_u8(p, c->rf_div);
    p = wr_u32(p, c->vco_khz);
    for (int i = 0; i < 6; i++) p = wr_u32(p, c->reg[i]);
    *on = (uint16_t)(p - out);
    console_printf("    ADF4351: VCO %lu kHz / %u, INT %u FRAC %u MOD %u -> %lu Hz\n",
                   (unsigned long)c->vco_khz, c->rf_div, c->int_val, c->frac, c->mod, (unsigned long)c->actual_hz);
    console_printf("    SPI: R5 %08lX R4 %08lX R3 %08lX R2 %08lX R1 %08lX R0 %08lX\n",
                   (unsigned long)c->reg[5], (unsigned long)c->reg[4], (unsigned long)c->reg[3],
                   (unsigned long)c->reg[2], (unsigned long)c->reg[1], (unsigned long)c->reg[0]);
    console_printf("    PLL %s\n", g_rs.pll_locked ? "LOCKED" : "NOT LOCKED");
    return ST_OK;
}

static uint8_t h_measure(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    meas_t m;
    reader_measure_once(&m);
    uint8_t *p = out;
    p = wr_u32(p, g_rs.lo_khz);
    p = wr_u16(p, m.adc_mag);
    p = wr_u16(p, m.adc_phs);
    p = wr_u16(p, m.vmag_mv);
    p = wr_u16(p, m.vphs_mv);
    p = wr_i16(p, (int16_t)lrintf(m.gain_db * 100.0f));
    p = wr_u16(p, (uint16_t)lrintf(m.phase_deg * 10.0f));
    p = wr_i16(p, (int16_t)lrintf(m.p_ref_dbm * 10.0f));
    p = wr_i16(p, (int16_t)lrintf(m.p_rx_dbm * 10.0f));
    p = wr_i16(p, (int16_t)lrintf(m.rssi_dbm * 10.0f));
    p = wr_u8(p, (uint8_t)m.clipped);
    p = wr_u8(p, g_rs.pll_locked);
    p = wr_u8(p, m.flags);
    *on = (uint16_t)(p - out);
    console_printf("CMD MEASURE @%lu kHz: ADC %u/%u -> VMAG %u mV VPHS %u mV -> gain %+.2f dB |phase| %.1f deg, RSSI %.1f dBm%s\n",
                   (unsigned long)g_rs.lo_khz, m.adc_mag, m.adc_phs, m.vmag_mv, m.vphs_mv,
                   m.gain_db, m.phase_deg, m.rssi_dbm, m.clipped ? " (CLIPPED)" : "");
    return ST_OK;
}

static uint8_t h_read_tag(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    tag_report_t r;
    console_printf("CMD READ_TAG sweep %lu..%lu kHz step %lu\n", (unsigned long)g_rs.profile.sweep_start_khz,
                   (unsigned long)g_rs.profile.sweep_stop_khz, (unsigned long)g_rs.profile.sweep_step_khz);
    reader_read_tag(&r);
    *on = tag_report_serialize(&r, out);
    commands_log_report(&r);
    return ST_OK;
}

static uint8_t h_get_sweep_data(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)n;
    uint16_t off = rd_u16(in), cnt = rd_u16(in + 2);
    uint16_t total = reader_sweep_points();
    if (off > total) return ST_OUT_OF_RANGE;
    if (cnt > 160) cnt = 160;
    if (off + cnt > total) cnt = (uint16_t)(total - off);
    uint8_t *p = out;
    p = wr_u16(p, total);
    p = wr_u16(p, off);
    p = wr_u16(p, cnt);
    p = wr_u32(p, reader_last_sweep_start());
    p = wr_u32(p, reader_last_sweep_step());
    int16_t bg0; int16_t rx; uint16_t ph;
    if (total) reader_sweep_point(0, &rx, &ph, &bg0); else bg0 = INT16_MIN;
    p = wr_u8(p, (uint8_t)(bg0 != INT16_MIN));
    for (uint16_t i = 0; i < cnt; i++) {
        int16_t bg;
        reader_sweep_point((uint16_t)(off + i), &rx, &ph, &bg);
        p = wr_i16(p, rx);
        p = wr_u16(p, ph);
        p = wr_i16(p, bg);
    }
    *on = (uint16_t)(p - out);
    if (console_verbose >= 1)
        console_printf("CMD GET_SWEEP_DATA points %u..%u of %u\n", off, (unsigned)(off + cnt), total);
    return ST_OK;
}

static uint8_t h_capture_bg(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    console_printf("CMD CAPTURE_BG (make sure no tag is in front of the antennas)\n");
    uint32_t t0 = plat_millis();
    reader_capture_background();
    uint32_t dt = plat_millis() - t0;
    wr_u16(out, reader_sweep_points());
    wr_u16(out + 2, (uint16_t)(dt > 65535 ? 65535 : dt));
    *on = 4;
    console_printf("    -> background stored, %u points in %lu ms\n", reader_sweep_points(), (unsigned long)dt);
    return ST_OK;
}

static uint8_t h_clear_bg(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n; (void)out;
    reader_clear_background();
    *on = 0;
    console_printf("CMD CLEAR_BG\n");
    return ST_OK;
}

static uint8_t sim_payload(uint8_t *out, uint16_t *on)
{
    sim_params_t sp;
    if (sim_get(&sp) != 0) return ST_NOT_SUPPORTED;
    uint8_t *p = out;
    p = wr_u8(p, (uint8_t)sp.tag_index);
    p = wr_u16(p, sp.distance_cm);
    p = wr_u16(p, sp.noise_x100);
    p = wr_u16(p, sp.q);
    int nt = sim_tag_count();
    p = wr_u8(p, (uint8_t)nt);
    for (int i = 0; i < nt; i++) {
        const sim_tag_t *t = sim_tag(i);
        p = wr_u32(p, t->code);
        memset(p, 0, 12);
        memcpy(p, t->name, strlen(t->name) < 12 ? strlen(t->name) : 12);
        p += 12;
        p = wr_u8(p, t->n_bits);
    }
    *on = (uint16_t)(p - out);
    return ST_OK;
}

static uint8_t h_sim_set(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    sim_params_t sp, cur;
    sp.tag_index = (int8_t)in[0];
    sp.distance_cm = rd_u16(in + 1);
    sp.noise_x100 = rd_u16(in + 3);
    sp.q = (n >= 7) ? rd_u16(in + 5) : ((sim_get(&cur) == 0) ? cur.q : 0);
    int r = sim_set(&sp);
    if (r == -1) { console_printf("CMD SIM_SET refused: hardware backend\n"); return ST_NOT_SUPPORTED; }
    if (r == -2) { console_printf("CMD SIM_SET out of range\n"); return ST_OUT_OF_RANGE; }
    const sim_tag_t *t = sim_tag(sp.tag_index);
    console_printf("CMD SIM_SET [simulated world] tag=%s distance=%u cm noise=%.2f dB Q=%u\n",
                   t ? t->name : "none", sp.distance_cm, sp.noise_x100 / 100.0, sp.q);
    return sim_payload(out, on);
}

static uint8_t h_sim_get(const uint8_t *in, uint16_t n, uint8_t *out, uint16_t *on)
{
    (void)in; (void)n;
    console_printf("CMD SIM_GET\n");
    return sim_payload(out, on);
}

/* ------------------------------------------------------------------ */

static const cmd_entry_t k_cmds[] = {
    { CMD_GET_INFO,       0, 0,  0, h_get_info       },
    { CMD_PING,           4, 4,  0, h_ping           },
    { CMD_GET_STATUS,     0, 0,  0, h_get_status     },
    { CMD_RESET_CONFIG,   0, 0,  1, h_reset_config   },
    { CMD_NV_SAVE,        0, 0,  1, h_nv_save        },
    { CMD_SET_MODE,       1, 3,  0, h_set_mode       },
    { CMD_GET_CONFIG,     0, 0,  0, h_get_config     },
    { CMD_SET_SWEEP,      12, 12, 1, h_set_sweep     },
    { CMD_SET_TX_POWER,   2, 2,  1, h_set_tx_power   },
    { CMD_SET_CARRIER,    1, 1,  1, h_set_carrier    },
    { CMD_SET_RX_CONFIG,  1, 1,  1, h_set_rx_config  },
    { CMD_SET_ACQ,        3, 3,  1, h_set_acq        },
    { CMD_SET_DETECT,     7, 3 + 4 * MAX_TAG_BITS, 1, h_set_detect },
    { CMD_GET_DETECT,     0, 0,  0, h_get_detect     },
    { CMD_SET_PROFILE,    PROFILE_FIXED_LEN + 4, PROFILE_FIXED_LEN + 4 * MAX_TAG_BITS, 1, h_set_profile },
    { CMD_GET_PROFILE,    0, 0,  0, h_get_profile    },
    { CMD_SET_CAL,        2 * CAL_FIELDS, 2 * CAL_FIELDS, 1, h_set_cal },
    { CMD_GET_CAL,        0, 0,  0, h_get_cal        },
    { CMD_SET_LO,         4, 4,  1, h_set_lo         },
    { CMD_MEASURE,        0, 0,  0, h_measure        },
    { CMD_ATTEN_SCAN,     1, 1,  1, h_atten_scan     },
    { CMD_AUTO_LEVEL,     0, 0,  1, h_auto_level     },
    { CMD_DB_INFO,        0, 0,  0, h_db_info        },
    { CMD_DB_GET,         2, 2,  0, h_db_get         },
    { CMD_DB_PUT,         5, 5 + TAGDB_NAME_LEN, 1, h_db_put },
    { CMD_DB_DELETE,      5, 5,  1, h_db_delete      },
    { CMD_DB_CLEAR,       0, 0,  1, h_db_clear       },
    { CMD_READ_TAG,       0, 0,  0, h_read_tag       },
    { CMD_GET_SWEEP_DATA, 4, 4,  0, h_get_sweep_data },
    { CMD_CAPTURE_BG,     0, 0,  1, h_capture_bg     },
    { CMD_CLEAR_BG,       0, 0,  1, h_clear_bg       },
    { CMD_SIM_SET,        5, 7,  0, h_sim_set        },
    { CMD_SIM_GET,        0, 0,  0, h_sim_get        },
};

uint8_t commands_dispatch(const frame_t *in, uint8_t *out, uint16_t *out_len)
{
    *out_len = 0;
    for (size_t i = 0; i < sizeof k_cmds / sizeof k_cmds[0]; i++) {
        const cmd_entry_t *e = &k_cmds[i];
        if (e->cmd != in->cmd) continue;
        if (in->payload_len < e->min_len || in->payload_len > e->max_len) {
            console_printf("CMD %s: BAD_LENGTH (%u bytes)\n", proto_cmd_name(in->cmd), in->payload_len);
            return ST_BAD_LENGTH;
        }
        if (e->config && g_rs.mode == 1) {
            console_printf("CMD %s: BUSY - reader is in AUTO mode, switch to RESPONSE mode first\n",
                           proto_cmd_name(in->cmd));
            return ST_BUSY;
        }
        return e->fn(in->payload, in->payload_len, out, out_len);
    }
    console_printf("CMD 0x%02X: UNKNOWN_CMD\n", in->cmd);
    return ST_UNKNOWN_CMD;
}

void commands_log_report(const tag_report_t *r)
{
    char bits[MAX_TAG_BITS + 1];
    bits_str(r->id, r->n_bits, bits);
    if (r->found)
        console_printf("    TAG #%lu  %.16s  ID 0x%03lX  bits(f1..f%u) %s  RSSI %.1f dBm  margin %.1f dB  phase %.1f deg  [%u pts, %u ms%s%s]\n",
                       (unsigned long)r->seq, r->matched ? r->name : "not in database", (unsigned long)r->id, r->n_bits, bits, r->rssi_x10 / 10.0,
                       r->margin_x10 / 10.0, r->phase_x10 / 10.0, r->points, r->sweep_ms,
                       r->bg_used ? ", bg-subtracted" : "", r->clipped ? ", CLIPPING" : "");
    else
        console_printf("    #%lu  no tag detected  (RSSI %.1f dBm, best margin %.1f dB, %u pts, %u ms)\n",
                       (unsigned long)r->seq, r->rssi_x10 / 10.0, r->margin_x10 / 10.0, r->points, r->sweep_ms);
    if (console_verbose >= 1) {
        char line[160]; int k = 0;
        k += snprintf(line + k, sizeof line - (size_t)k, "    notch depth dB:");
        for (int i = 0; i < r->n_bits && k < (int)sizeof line - 8; i++)
            k += snprintf(line + k, sizeof line - (size_t)k, " %.1f", r->depth_x10[i] / 10.0);
        console_printf("%s\n", line);
    }
}

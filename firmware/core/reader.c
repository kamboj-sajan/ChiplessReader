/*
 * reader.c - the reader engine. Identical on the STM32 and in the virtual reader.
 *
 * READ_TAG = one frequency sweep + decode + database lookup:
 *   for each frequency: program ADF4351 -> wait for PLL lock -> settle -> average N ADC
 *   samples of VMAG/VPHS -> convert to received power at the RX antenna (dBm).
 *   Then, for every bit frequency of the tag profile, compare magnitude and phase:
 *     - the notch depth is the level on either side of the bit minus the lowest level at it
 *     - the phase swing is how far the AD8302 phase moves across the bit
 *   depth >= threshold, with the phase confirming it -> bit = 1.
 *   The resulting pattern is looked up in the tag database.
 */
#include <string.h>
#include <stddef.h>
#include <math.h>
#include <limits.h>
#include "reader.h"
#include "platform.h"
#include "rf_backend.h"
#include "console.h"
#include "protocol.h"
#include "calibration.h"
#include "tagdb.h"
#include "nvstore.h"

reader_state_t g_rs;
tag_report_t   g_last_report;      /* latest read - watch it in STM32CubeIDE Live Expressions */

static int16_t  s_rx[MAX_SWEEP_POINTS];     /* dBm x100 at RX antenna */
static uint16_t s_ph[MAX_SWEEP_POINTS];     /* |phase| deg x10        */
static int16_t  s_bg[MAX_SWEEP_POINTS];     /* background, dBm x100   */
static float    s_lvl[MAX_SWEEP_POINTS];    /* decode working copy, dB */
static uint16_t s_n;
static uint32_t s_start, s_step;
static uint16_t s_bg_n;
static uint32_t s_bg_start, s_bg_step;
static uint16_t s_clipped, s_unlocked;
static uint32_t s_sweep_ms;
static uint32_t s_seq;
static float    s_gain_min, s_gain_max;

/* ---------------- configuration ---------------- */

void reader_layout_bits(reader_profile_t *p, uint8_t n_bits, uint32_t start_khz, uint32_t stop_khz)
{
    uint32_t span = stop_khz - start_khz;
    p->n_bits = n_bits;
    for (int k = 0; k < MAX_TAG_BITS; k++)
        p->bit_khz[k] = (k < n_bits) ? start_khz + (span * (2u * (uint32_t)k + 1u)) / (2u * n_bits) : 0;
}

void reader_defaults(void)
{
    reader_profile_t *p = &g_rs.profile;
    memset(p, 0, sizeof *p);
    memcpy(p->name, DEF_PROFILE_NAME, strlen(DEF_PROFILE_NAME));
    p->sweep_start_khz = DEF_SWEEP_START_KHZ;
    p->sweep_stop_khz = DEF_SWEEP_STOP_KHZ;
    p->sweep_step_khz = DEF_SWEEP_STEP_KHZ;
    p->settle_us = DEF_SETTLE_US;
    p->averages = DEF_AVERAGES;
    p->threshold_x10 = DEF_THRESHOLD_X10;
    p->phase_thr_x10 = DEF_PHASE_THR_X10;
    p->auto_interval_ms = DEF_AUTO_INTERVAL_MS;
    p->max_bit_errors = DEF_MAX_BIT_ERRORS;
    reader_layout_bits(p, DEF_N_BITS, BAND_START_KHZ, BAND_STOP_KHZ);

    g_rs.lo_khz = DEF_LO_KHZ;
    g_rs.tx_level = DEF_TX_LEVEL;
    g_rs.pa_en = DEF_PA_EN;
    g_rs.ref_atten = DEF_REF_ATTEN_HALF_DB;
    g_rs.mode = 0;
    g_rs.carrier = 0;
    g_rs.bg_valid = 0;
    cal_defaults();
}

void reader_init(void)
{
    memset(&g_rs, 0, sizeof g_rs);
    reader_defaults();
    tagdb_clear();
    rf_backend_seed_tagdb();
    g_rs.nv_loaded = (nvstore_load() == 0);
    rf_backend_init();
    plat_pa_enable(0);
    rf_backend_on_pa(0);
    /* the attenuator goes first, so the AD8302 is protected before anything can transmit */
    reader_apply_atten();
    reader_set_lo(g_rs.lo_khz);
}

float reader_tx_power_dbm(void)
{
    return cal_tx_dbm(g_rs.tx_level, g_rs.pa_en);
}

/* The PA runs only while the reader is measuring (or when a carrier is asked for), so the
 * board does not radiate 1 W just by being powered. */
static void pa_gate(int on)
{
    int want = on && g_rs.pa_en;
    plat_pa_enable(want);
    rf_backend_on_pa(want);
    if (want) plat_delay_us(PA_RAMP_US);
}

void reader_apply_tx_power(void)
{
    pa_gate(g_rs.carrier);
    /* output power lives in ADF4351 R4: reprogram at the current frequency */
    if (g_rs.lo_khz) reader_set_lo(g_rs.lo_khz);
}

void reader_apply_atten(void)
{
    plat_pe4312_write(g_rs.ref_atten & 0x3F);
    rf_backend_on_pe4312(g_rs.ref_atten & 0x3F);
    plat_delay_us(ATTEN_SETTLE_US);
}

void reader_set_carrier(int on)
{
    g_rs.carrier = (uint8_t)(on != 0);
    pa_gate(g_rs.carrier);
}

/* full = program all six registers; otherwise only those that changed */
static int tune(uint32_t khz, adf4351_cfg_t *cfg, int full)
{
    if (adf4351_calc(khz, g_rs.tx_level, 1, cfg) != 0) return ST_OUT_OF_RANGE;
    if (full) adf4351_program(cfg); else adf4351_program_changed(cfg);
    return adf4351_wait_lock(ADF_LOCK_TIMEOUT_US) ? ST_OK : ST_PLL_UNLOCKED;
}

int reader_set_lo(uint32_t khz)
{
    adf4351_cfg_t cfg;
    int st = tune(khz, &cfg, 1);
    if (st == ST_OUT_OF_RANGE) return st;
    g_rs.lo_khz = khz;
    g_rs.adf = cfg;
    g_rs.pll_locked = (st == ST_OK);
    return st;
}

/* ---------------- measurement ---------------- */

void reader_measure(meas_t *m)
{
    uint32_t sm = 0, sp = 0;
    uint8_t n = g_rs.profile.averages ? g_rs.profile.averages : 1;
    for (uint8_t i = 0; i < n; i++) {
        uint16_t a, b;
        rf_backend_read_adc(&a, &b);
        sm += a; sp += b;
    }
    m->adc_mag = (uint16_t)((sm + n / 2) / n);
    m->adc_phs = (uint16_t)((sp + n / 2) / n);
    /* the simulated front-end produces counts against the nominal reference; real hardware
     * uses the VDDA measured with VREFINT */
    const float vref = rf_backend_is_sim() ? (float)ADC_VREF_MV : (float)plat_adc_vref_mv();
    float vmag = m->adc_mag * vref / ADC_FULL_SCALE;
    float vphs = m->adc_phs * vref / ADC_FULL_SCALE;
    m->vmag_mv = (uint16_t)(vmag + 0.5f);
    m->vphs_mv = (uint16_t)(vphs + 0.5f);
    m->gain_db = (vmag - g_cal.vmag_center_mv) / g_cal.vmag_slope_mv_db;
    m->clipped = (vmag < AD8302_VMAG_MIN_MV || vmag > AD8302_VMAG_MAX_MV);
    float ph = 90.0f - (vphs - g_cal.vphs_center_mv) / g_cal.vphs_slope_mv_deg;
    if (ph < 0) ph = 0;
    if (ph > 180) ph = 180;
    m->phase_deg = ph;
    m->p_ref_dbm = cal_inpa_dbm(g_rs.tx_level, g_rs.pa_en, g_rs.ref_atten);
    m->p_rx_dbm = m->p_ref_dbm - m->gain_db;
    m->rssi_dbm = m->p_rx_dbm - g_cal.lna_gain_db + g_cal.rx_filter_il_db + g_cal.rssi_trim_db;
    m->flags = 0;
    if (m->clipped) m->flags |= RF_VMAG_CLIP;
    if (m->p_ref_dbm > AD8302_INPUT_MAX_DBM) m->flags |= RF_INPA_HIGH;
    if (m->p_ref_dbm < AD8302_INPUT_MIN_DBM) m->flags |= RF_INPA_LOW;
    if (m->p_rx_dbm > AD8302_INPUT_MAX_DBM) m->flags |= RF_INPB_HIGH;
    if (m->p_rx_dbm < AD8302_INPUT_MIN_DBM) m->flags |= RF_INPB_LOW;
}

void reader_measure_once(meas_t *m)
{
    pa_gate(1);
    reader_measure(m);
    pa_gate(g_rs.carrier);
}

/* ---------------- sweep ---------------- */

uint16_t reader_sweep_points(void) { return s_n; }
uint32_t reader_last_sweep_start(void) { return s_start; }
uint32_t reader_last_sweep_step(void) { return s_step; }

static int background_usable(void)
{
    return g_rs.bg_valid && s_bg_n == s_n && s_bg_start == s_start && s_bg_step == s_step;
}

void reader_sweep_point(uint16_t i, int16_t *rx, uint16_t *ph, int16_t *bg)
{
    *rx = s_rx[i];
    *ph = s_ph[i];
    *bg = background_usable() ? s_bg[i] : INT16_MIN;
}

int reader_sweep(void)
{
    const reader_profile_t *p = &g_rs.profile;
    uint32_t start = p->sweep_start_khz, step = p->sweep_step_khz;
    uint32_t n = (p->sweep_stop_khz - start) / step + 1;
    if (n > MAX_SWEEP_POINTS) n = MAX_SWEEP_POINTS;

    uint32_t t0 = plat_millis();
    s_clipped = s_unlocked = 0;
    s_gain_min = 1e9f;
    s_gain_max = -1e9f;
    pa_gate(1);
    for (uint32_t i = 0; i < n; i++) {
        adf4351_cfg_t cfg;
        uint32_t f = start + i * step;
        int st = tune(f, &cfg, i == 0);
        if (st != ST_OK) s_unlocked++;
        plat_delay_us(p->settle_us);
        meas_t m;
        reader_measure(&m);
        if (m.clipped) s_clipped++;
        if (m.gain_db < s_gain_min) s_gain_min = m.gain_db;
        if (m.gain_db > s_gain_max) s_gain_max = m.gain_db;
        float rx = m.rssi_dbm * 100.0f;
        if (rx < -32000.0f) rx = -32000.0f;
        if (rx > 32000.0f) rx = 32000.0f;
        s_rx[i] = (int16_t)lrintf(rx);
        s_ph[i] = (uint16_t)lrintf(m.phase_deg * 10.0f);
        if (console_verbose >= 2)
            console_printf("    %7.3f MHz  ADC %4u/%4u  VMAG %4u mV  gain %+6.2f dB  |ph| %5.1f  rx %+7.2f dBm%s\n",
                           f / 1000.0, m.adc_mag, m.adc_phs, m.vmag_mv, m.gain_db, m.phase_deg,
                           m.rssi_dbm, m.clipped ? "  CLIP" : "");
    }
    pa_gate(g_rs.carrier);
    s_n = (uint16_t)n;
    s_start = start;
    s_step = step;
    s_sweep_ms = plat_millis() - t0;

    /* leave the synthesizer where the SDK last put it */
    reader_set_lo(g_rs.lo_khz);
    return ST_OK;
}

int reader_capture_background(void)
{
    reader_sweep();
    memcpy(s_bg, s_rx, sizeof(int16_t) * s_n);
    s_bg_n = s_n;
    s_bg_start = s_start;
    s_bg_step = s_step;
    g_rs.bg_valid = 1;
    return ST_OK;
}

void reader_clear_background(void) { g_rs.bg_valid = 0; }

/* ---------------- decode ---------------- */

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

/* s_lvl[i] = received level with the background removed, 3-point median to reject single-point noise */
static void build_levels(int use_bg, int n)
{
    for (int i = 0; i < n; i++) {
        float a = (s_rx[i > 0 ? i - 1 : i] - (use_bg ? s_bg[i > 0 ? i - 1 : i] : 0)) / 100.0f;
        float b = (s_rx[i] - (use_bg ? s_bg[i] : 0)) / 100.0f;
        float c = (s_rx[i < n - 1 ? i + 1 : i] - (use_bg ? s_bg[i < n - 1 ? i + 1 : i] : 0)) / 100.0f;
        float lo = fminf(fminf(a, b), c), hi = fmaxf(fmaxf(a, b), c);
        s_lvl[i] = a + b + c - lo - hi;
    }
}

/* distance from bit k to its nearest neighbour; with one bit, the whole sweep */
static float bit_spacing_khz(const reader_profile_t *p, int k, float span_khz)
{
    float spacing = span_khz;
    float fk = (float)p->bit_khz[k];
    for (int j = 0; j < p->n_bits; j++)
        if (j != k) {
            float d = fabsf((float)p->bit_khz[j] - fk);
            if (d > 0 && d < spacing) spacing = d;
        }
    return spacing;
}

/*
 * Notch depth and phase swing at one bit frequency.
 *
 *     shoulder            shoulder       The notch can sit slightly off nominal, so the search
 *     ----.                 .----        window is +/-20 % of the bit spacing. The shoulders run
 *          \               /             from there out to the midpoints with the neighbouring
 *           \_____________/              bits. Taking the lower of the two shoulders means a '0'
 *            |<- search ->|              next to a '1' does not borrow that notch's slope: its
 *     |<------ spacing ------>|          shoulder on that side is just as low, so its depth stays ~0.
 */
static void measure_bit(const reader_profile_t *p, int k, int n, float *depth, float *swing, int *min_i)
{
    const float fk = (float)p->bit_khz[k];
    const float last_f = (float)s_start + (float)(n - 1) * s_step;
    *depth = 0;
    *swing = 0;
    *min_i = -1;
    if (fk < s_start || fk > last_f) return;

    const float half = bit_spacing_khz(p, k, last_f - (float)s_start) / 2.0f;
    const float search = clampf(half * 0.4f, (float)s_step, 1500.0f);

    float mn = 1e9f, left = -1e9f, right = -1e9f;
    float ph_min = 1e9f, ph_max = -1e9f;
    for (int i = 0; i < n; i++) {
        const float f = (float)s_start + (float)i * s_step;
        const float df = f - fk;
        if (fabsf(df) > half) continue;
        if (fabsf(df) <= search) {
            if (s_lvl[i] < mn) { mn = s_lvl[i]; *min_i = i; }
            const float ph = s_ph[i] / 10.0f;
            if (ph < ph_min) ph_min = ph;
            if (ph > ph_max) ph_max = ph;
        } else if (df < 0) {
            if (s_lvl[i] > left) left = s_lvl[i];
        } else {
            if (s_lvl[i] > right) right = s_lvl[i];
        }
    }
    if (*min_i < 0) return;
    /* a bit at the edge of the sweep has a shoulder on one side only */
    float shoulder = fminf(left, right);
    if (left <= -1e8f) shoulder = right;
    if (right <= -1e8f) shoulder = left;
    if (shoulder <= -1e8f) return;              /* sweep too coarse to see this bit */
    *depth = shoulder - mn;
    *swing = ph_max - ph_min;
    if (*depth < 0) *depth = 0;
}

int reader_read_tag(tag_report_t *r)
{
    reader_sweep();

    const reader_profile_t *p = &g_rs.profile;
    const int use_bg = background_usable();
    const float thr = p->threshold_x10 / 10.0f;
    const float phase_thr = p->phase_thr_x10 / 10.0f;
    const int n = s_n;

    memset(r, 0, sizeof *r);
    r->seq = ++s_seq;
    r->n_bits = p->n_bits;
    r->points = s_n;
    r->sweep_ms = (uint16_t)(s_sweep_ms > 65535 ? 65535 : s_sweep_ms);
    r->bg_used = (uint8_t)use_bg;
    r->clipped = s_clipped;
    r->unlocked = s_unlocked;
    r->db_index = -1;

    /* band-average received power (average in mW) */
    double pw = 0;
    for (int i = 0; i < n; i++) pw += pow(10.0, s_rx[i] / 1000.0);
    r->rssi_x10 = (int16_t)lrint(100.0 * log10(pw / (n ? n : 1)));

    build_levels(use_bg, n);

    float min_margin = 1e9f, deepest = -1e9f;
    int deepest_idx = 0;
    uint32_t id = 0;

    for (int k = 0; k < p->n_bits; k++) {
        float depth, swing;
        int min_i;
        measure_bit(p, k, n, &depth, &swing, &min_i);
        r->depth_x10[k] = (int16_t)lrintf(depth * 10.0f);
        r->swing_x10[k] = (int16_t)lrintf(swing * 10.0f);
        if (min_i >= 0 && depth > deepest) { deepest = depth; deepest_idx = min_i; }

        /* magnitude decides; phase has to agree unless the notch is unmistakably deep. A level
         * step with no resonance behind it (a band change, a reflection) moves no phase. */
        const int phase_ok = (phase_thr <= 0.0f) || (swing >= phase_thr) || (depth >= 2.0f * thr);
        if (depth >= thr && phase_ok) id |= (1u << k);

        float mg = fabsf(depth - thr);
        if (mg < min_margin) min_margin = mg;
    }

    r->id = id;
    r->margin_x10 = (int16_t)lrintf((min_margin > 3000.0f ? 0.0f : min_margin) * 10.0f);
    r->phase_x10 = n ? s_ph[deepest_idx] : 0;
    r->found = (id != 0) && (s_unlocked < (uint16_t)(n / 2));

    /* compare the decoded pattern against the database */
    uint8_t errs = 0;
    int idx = r->found ? tagdb_match(id, p->n_bits, p->max_bit_errors, &errs) : -1;
    if (idx >= 0) {
        r->matched = 1;
        r->bit_errors = errs;
        r->db_index = (int16_t)idx;
        memcpy(r->name, g_tagdb.entry[idx].name, TAGDB_NAME_LEN);
    }

    g_rs.reads++;
    if (r->found) g_rs.tags_found++;
    g_last_report = *r;
    return ST_OK;
}

uint16_t tag_report_serialize(const tag_report_t *r, uint8_t *out)
{
    uint8_t *p = out;
    p = wr_u32(p, r->seq);
    p = wr_u8(p, r->found);
    p = wr_u8(p, r->n_bits);
    p = wr_u32(p, r->id);
    p = wr_i16(p, r->rssi_x10);
    p = wr_u16(p, r->phase_x10);
    p = wr_i16(p, r->margin_x10);
    p = wr_u16(p, r->sweep_ms);
    p = wr_u16(p, r->points);
    p = wr_u8(p, r->bg_used);
    p = wr_u16(p, r->clipped);
    p = wr_u16(p, r->unlocked);
    for (int k = 0; k < r->n_bits; k++) p = wr_i16(p, r->depth_x10[k]);
    for (int k = 0; k < r->n_bits; k++) p = wr_i16(p, r->swing_x10[k]);
    p = wr_u8(p, r->matched);
    p = wr_u8(p, r->bit_errors);
    p = wr_i16(p, r->db_index);
    memcpy(p, r->name, TAGDB_NAME_LEN);
    p += TAGDB_NAME_LEN;
    return (uint16_t)(p - out);
}

/* ---------------- calibration ---------------- */

/*
 * Choose the PE4312 setting that centres the AD8302 on what the last sweep saw.
 * The reference only moves VMAG: 1 dB more attenuation lowers P(INPA) - P(INPB) by 1 dB. So the
 * setting that puts the middle of the measured gain range at 0 dB is known after one sweep. It
 * is repeated because a clipped sweep understates how far off the setting is.
 */
int reader_auto_level(auto_level_t *res)
{
    const uint8_t min_atten = cal_min_atten_half_db(g_rs.tx_level, g_rs.pa_en);
    memset(res, 0, sizeof *res);
    res->old_atten = g_rs.ref_atten;
    for (int it = 0; it < 4; it++) {
        reader_sweep();
        res->iterations = (uint8_t)(it + 1);
        const float centre = 0.5f * (s_gain_min + s_gain_max);
        long want = (long)g_rs.ref_atten + lrintf(centre * 2.0f);
        if (want < min_atten) want = min_atten;
        if (want > 63) want = 63;
        if (want == g_rs.ref_atten) break;
        g_rs.ref_atten = (uint8_t)want;
        reader_apply_atten();
    }
    reader_sweep();
    meas_t m;
    reader_measure_once(&m);
    res->new_atten = g_rs.ref_atten;
    res->gain_min_db = s_gain_min;
    res->gain_max_db = s_gain_max;
    res->inpa_dbm = m.p_ref_dbm;
    res->clipped = s_clipped;
    res->flags = m.flags;
    return ST_OK;
}

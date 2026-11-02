/*
 * rf_sim.c - simulated RF front-end + chipless tag (RF_BACKEND_SIM).
 *
 * Signal path modelled (same as the architecture diagram):
 *
 *   ADF4351 -> LFCN-1000 -> MAX2235 PA -> coupler(-20 dB) -> TX antenna ~~> tag ~~> RX antenna
 *                                            |                                        |
 *                                       PE4312 atten                          HMC8410 LNA -> filters
 *                                            |                                        |
 *                                        AD8302 INPA  (reference)          AD8302 INPB (echo)
 *                                                      VMAG / VPHS -> 12-bit ADC
 *
 * Channel between the antennas (complex, per frequency f):
 *   S(f) = L * e^{-j2*pi*f*tauL}                                   direct TX->RX leakage
 *        + A(d) * e^{-j2*pi*f*tauT} * PROD_k [1 - kappa / (1 + j*2Q*(f - f_k)/f_k)]   tag
 * where the product runs over the resonators present on the tag (bit = 1). Each resonator
 * absorbs energy near its frequency and leaves a notch in the echo.
 *
 * The RF chain levels come from the same datasheet numbers as app_config.h. The channel numbers
 * (isolation, echo level, notch depth, Q) are estimates until real tags are measured.
 * This file is the "true world": it uses the fixed CAL_* values, not g_cal, so a wrong
 * calibration entered in the app shows up as a wrong reading, as it would on real hardware.
 */
#include "rf_backend.h"
#include "app_config.h"
#include "calibration.h"
#include "tagdb.h"

#if defined(RF_BACKEND_SIM)

#include <math.h>
#include <string.h>

#define PI_F 3.14159265f

/* channel model */
#define SIM_LEAK_DB        (-70.0f)     /* TX->RX antenna isolation                 */
#define SIM_TAG_DB_20CM    (-52.0f)     /* tag echo relative to TX power at 20 cm   */
#define SIM_TAU_LEAK_NS    2.0f
#define SIM_KAPPA          0.9f         /* notch depth factor (-20 dB)              */
#define SIM_PHASE_NOISE_DEG 0.3f
#define SIM_INPUT_FLOOR_DBM AD8302_INPUT_MIN_DBM
#define SIM_INPUT_CEIL_DBM  3.0f        /* the log amps stop responding just past 0 dBm */

/* code: bit k = resonator k, so the pattern 1010110011 (f1 first) is 0x335 */
static const sim_tag_t k_tags[] = {
    { "SINGLE-1",   1, 0x001 },     /* 1          */
    { "DOUBLE-10",  2, 0x001 },     /* 10         */
    { "TEN-A",     10, 0x335 },     /* 1010110011 */
    { "TEN-B",     10, 0x0CA },     /* 0101001100 */
    { "TEN-C",     10, 0x3FF },     /* 1111111111 */
    { "TEN-D",     10, 0x155 },     /* 1010101010 */
    { "TEN-E",     10, 0x201 },     /* 1000000001 */
};
#define N_TAGS ((int)(sizeof k_tags / sizeof k_tags[0]))

/* what the "hardware" currently is, decoded from the control words */
static struct {
    uint32_t r[6];
    int      r_seen[6];
    float    f_hz;
    int      locked;
    int      rf_on;
    int      power_level;
    uint8_t  atten_half_db;
    int      pa_on;
} hw;

#define SIM_DEFAULT_Q 2000u          /* see docs/DESIGN_NOTES.md: what 10 bits in 5 MHz needs */

static sim_params_t sp = { 2, 20, 5, SIM_DEFAULT_Q };
static uint32_t rng = 0x12345678u;

static float urand(void)
{
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return (float)(rng >> 8) / 16777216.0f;
}
static float nrand(void)   /* Box-Muller */
{
    float u1 = urand(), u2 = urand();
    if (u1 < 1e-7f) u1 = 1e-7f;
    return sqrtf(-2.0f * logf(u1)) * cosf(2.0f * PI_F * u2);
}

void rf_backend_init(void)
{
    memset(&hw, 0, sizeof hw);
}
const char *rf_backend_name(void) { return "SIM"; }
int rf_backend_is_sim(void) { return 1; }

/* decode the synthesizer exactly as the chip would */
static void recompute_synth(void)
{
    if (!hw.r_seen[0] || !hw.r_seen[1] || !hw.r_seen[2] || !hw.r_seen[4]) { hw.locked = 0; return; }
    uint32_t n_int = (hw.r[0] >> 15) & 0xFFFF;
    uint32_t frac  = (hw.r[0] >> 3) & 0xFFF;
    uint32_t mod   = (hw.r[1] >> 3) & 0xFFF;
    uint32_t rcnt  = (hw.r[2] >> 14) & 0x3FF;
    uint32_t dbl   = (hw.r[2] >> 25) & 1;
    uint32_t rdiv2 = (hw.r[2] >> 24) & 1;
    uint32_t divsel= (hw.r[4] >> 20) & 7;
    uint32_t fb    = (hw.r[4] >> 23) & 1;
    if (mod < 2 || rcnt == 0) { hw.locked = 0; return; }
    double pfd = ADF_REF_KHZ * 1000.0 * (1 + dbl) / (rcnt * (1 + rdiv2));
    double n = n_int + (double)frac / mod;
    double div = (double)(1u << divsel);
    double vco = fb ? pfd * n : pfd * n * div;
    hw.f_hz = (float)(vco / div);
    hw.locked = (vco >= 2.2e9 && vco <= 4.4e9);
    hw.rf_on = (hw.r[4] >> 5) & 1;
    hw.power_level = (int)((hw.r[4] >> 3) & 3);
}

void rf_backend_on_adf_word(uint32_t w)
{
    int ctrl = (int)(w & 7u);
    if (ctrl > 5) return;
    hw.r[ctrl] = w;
    hw.r_seen[ctrl] = 1;
    if (ctrl == 0) recompute_synth();   /* R0 write triggers the update on the real chip */
}
void rf_backend_on_pe4312(uint8_t w) { hw.atten_half_db = (uint8_t)(w & 0x3F); }
void rf_backend_on_pa(int on)        { hw.pa_on = on; }
int  rf_backend_lock_detect(void)    { return hw.locked; }

/* complex helpers */
typedef struct { float re, im; } cpx;
static cpx cmul(cpx a, cpx b) { cpx r = { a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re }; return r; }
static cpx cdiv(cpx a, cpx b) { float d = b.re * b.re + b.im * b.im; cpx r = { (a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d }; return r; }
static cpx cexpj(float ph) { cpx r = { cosf(ph), sinf(ph) }; return r; }

static cpx channel(float f)
{
    cpx s = cexpj(-2.0f * PI_F * f * SIM_TAU_LEAK_NS * 1e-9f);
    float aL = powf(10.0f, SIM_LEAK_DB / 20.0f);
    s.re *= aL; s.im *= aL;

    if (sp.tag_index >= 0 && sp.tag_index < N_TAGS) {
        float d_m = sp.distance_cm / 100.0f;
        float a_db = SIM_TAG_DB_20CM - 40.0f * log10f(sp.distance_cm / 20.0f);  /* radar 1/r^4 */
        float aT = powf(10.0f, a_db / 20.0f);
        float tau = SIM_TAU_LEAK_NS * 1e-9f + 2.0f * d_m / 3e8f;
        cpx t = cexpj(-2.0f * PI_F * f * tau);
        t.re *= aT; t.im *= aT;
        const uint32_t code = k_tags[sp.tag_index].code;
        const int n_bits = k_tags[sp.tag_index].n_bits;
        for (int k = 0; k < n_bits; k++) {
            if (!(code & (1u << k))) continue;
            float fk = (float)sim_bit_khz(k, n_bits) * 1000.0f;
            cpx den = { 1.0f, 2.0f * (float)sp.q * (f - fk) / fk };
            cpx one = { 1.0f, 0.0f };
            cpx kap = { SIM_KAPPA, 0.0f };
            cpx h = cdiv(kap, den);
            cpx notch = { one.re - h.re, one.im - h.im };
            t = cmul(t, notch);
        }
        s.re += t.re; s.im += t.im;
    }
    return s;
}

static uint16_t to_counts(float volts)
{
    float c = volts * 1000.0f / ADC_VREF_MV * ADC_FULL_SCALE;
    if (c < 0) c = 0;
    if (c > ADC_FULL_SCALE) c = ADC_FULL_SCALE;
    return (uint16_t)(c + 0.5f);
}

void rf_backend_read_adc(uint16_t *vmag_counts, uint16_t *vphs_counts)
{
    float p_a = -90.0f, p_b = -90.0f, phase = 90.0f;

    if (hw.locked && hw.rf_on) {
        float pin = cal_level_dbm((uint8_t)hw.power_level) - CAL_TX_FILTER_IL_DB;
        float pout = hw.pa_on ? cal_max2235_pout_dbm(pin) : pin - CAL_PA_OFF_ISOLATION_DB;
        float p_tx_ant = pout - CAL_COUPLER_THRU_DB;
        p_a = pout - CAL_COUPLER_DB - CAL_ATTEN_IL_DB - hw.atten_half_db * 0.5f;

        cpx s = channel(hw.f_hz);
        float mag2 = s.re * s.re + s.im * s.im;
        float s_db = 10.0f * log10f(mag2 > 1e-20f ? mag2 : 1e-20f);
        p_b = p_tx_ant + s_db + CAL_LNA_GAIN_DB - CAL_RX_FILTER_IL_DB;
        phase = atan2f(s.im, s.re) * 180.0f / PI_F;      /* INPA taken as 0 deg reference */
    }
    if (p_a < SIM_INPUT_FLOOR_DBM) p_a = SIM_INPUT_FLOOR_DBM;
    if (p_b < SIM_INPUT_FLOOR_DBM) p_b = SIM_INPUT_FLOOR_DBM;
    if (p_b > SIM_INPUT_CEIL_DBM) p_b = SIM_INPUT_CEIL_DBM;

    /* AD8302: VMAG = VCP + 30 mV/dB * (PA - PB), clipped to +/-30 dB (0 .. 1.8 V) */
    float gain = p_a - p_b + nrand() * sp.noise_x100 / 100.0f;
    if (gain > 30.0f) gain = 30.0f;
    if (gain < -30.0f) gain = -30.0f;
    float vmag = (AD8302_VCP_MV + AD8302_MAG_MV_PER_DB * gain) / 1000.0f;

    /* VPHS = VCP - 10 mV/deg * (|phi| - 90), i.e. 1.8 V at 0 deg, 0 V at 180 deg */
    float aphi = fabsf(phase + nrand() * SIM_PHASE_NOISE_DEG);
    if (aphi > 180.0f) aphi = 360.0f - aphi;
    float vphs = (AD8302_VCP_MV - AD8302_PHS_MV_PER_DEG * (aphi - 90.0f)) / 1000.0f;

    *vmag_counts = to_counts(vmag);
    *vphs_counts = to_counts(vphs);
}

/* ---- simulation controls ---- */
int sim_set(const sim_params_t *p)
{
    if (p->tag_index < -1 || p->tag_index >= N_TAGS) return -2;
    if (p->distance_cm < 5 || p->distance_cm > 300) return -2;
    if (p->noise_x100 > 500) return -2;
    if (p->q < 20 || p->q > 20000) return -2;
    sp = *p;
    return 0;
}
int sim_get(sim_params_t *p) { *p = sp; return 0; }
int sim_tag_count(void) { return N_TAGS; }
const sim_tag_t *sim_tag(int i) { return (i >= 0 && i < N_TAGS) ? &k_tags[i] : 0; }
/* a tag with n bits splits the band into n equal cells with one resonator at each centre */
uint32_t sim_bit_khz(int k, int n_bits)
{
    uint32_t span = BAND_STOP_KHZ - BAND_START_KHZ;
    return BAND_START_KHZ + (span * (2u * (uint32_t)k + 1u)) / (2u * (uint32_t)n_bits);
}

void rf_backend_seed_tagdb(void)
{
    for (int i = 0; i < N_TAGS; i++)
        tagdb_put(k_tags[i].code, k_tags[i].n_bits, k_tags[i].name, (int)strlen(k_tags[i].name));
}

#endif /* RF_BACKEND_SIM */

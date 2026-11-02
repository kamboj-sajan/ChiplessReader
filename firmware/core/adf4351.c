/*
 * adf4351.c - register maths follow the ADF4351 datasheet (Rev. A) register map.
 *
 *   f_PFD = REF * (1 + D) / (R * (1 + T))            (D = doubler, T = ref/2; both off)
 *   f_VCO = f_PFD * (INT + FRAC / MOD)               (feedback from VCO fundamental)
 *   f_OUT = f_VCO / RF_DIV,  VCO range 2.2 .. 4.4 GHz
 *
 * Example 865 MHz, 25 MHz ref: RF_DIV 4, VCO 3460 MHz, INT 138, FRAC/MOD 2/5
 *   R5 00580005  R4 00AC803C  R3 000004B3  R2 18004E42  R1 08008029  R0 00450010
 */
#include "adf4351.h"
#include "app_config.h"
#include "platform.h"
#include "rf_backend.h"

static uint32_t gcd_u32(uint32_t a, uint32_t b)
{
    while (b) { uint32_t t = a % b; a = b; b = t; }
    return a;
}

int adf4351_calc(uint32_t out_khz, uint8_t power_level, int rf_enable, adf4351_cfg_t *c)
{
    if (out_khz < ADF_MIN_KHZ || out_khz > ADF_MAX_KHZ) return -1;
    if (power_level > 3) power_level = 3;

    /* 1. output divider: smallest power of two putting the VCO >= 2.2 GHz */
    uint32_t div = 1, divsel = 0;
    while ((uint64_t)out_khz * div < 2200000u && div < 64) { div <<= 1; divsel++; }
    uint32_t vco_khz = out_khz * div;

    /* 2. N = VCO / PFD = INT + FRAC/MOD */
    const uint32_t pfd_khz = ADF_REF_KHZ / ADF_R_COUNTER;
    uint32_t n_int = vco_khz / pfd_khz;
    uint32_t rem   = vco_khz % pfd_khz;
    uint32_t frac, mod;
    if (rem == 0) {
        frac = 0; mod = 2;                      /* integer-N; MOD must still be >= 2 */
    } else {
        uint32_t g = gcd_u32(rem, pfd_khz);
        frac = rem / g; mod = pfd_khz / g;
        if (mod > 4095) {                       /* 12-bit MOD: nearest representable value */
            mod  = 4095;
            frac = (uint32_t)(((uint64_t)rem * mod + pfd_khz / 2) / pfd_khz);
            if (frac >= mod) { frac = 0; n_int++; }
            if (frac == 0) mod = 2;
        }
    }
    const int int_n = (frac == 0);

    /* 3. band-select clock <= 125 kHz */
    uint32_t bsc = (pfd_khz + 124) / 125;
    if (bsc > 255) bsc = 255;
    if (bsc < 1) bsc = 1;

    /* 4. registers */
    c->reg[0] = (n_int << 15) | (frac << 3) | 0u;
    c->reg[1] = (1u << 27)            /* prescaler 8/9 (INT >= 75)          */
              | (1u << 15)            /* phase word = 1 (recommended)       */
              | (mod << 3) | 1u;
    c->reg[2] = (6u << 26)            /* MUXOUT = digital lock detect        */
              | ((uint32_t)ADF_R_COUNTER << 14)
              | (7u << 9)             /* charge pump 2.50 mA                 */
              | (int_n ? (1u << 8) : 0u)   /* LDF: 1 = INT-N, 0 = FRAC-N     */
              | (int_n ? (1u << 7) : 0u)   /* LDP: 6 ns for INT-N            */
              | (1u << 6)             /* PD polarity positive                */
              | 2u;
    c->reg[3] = (int_n ? (1u << 22) : 0u)  /* ABP 3 ns for INT-N             */
              | (150u << 3) | 3u;
    c->reg[4] = (1u << 23)            /* feedback from VCO fundamental       */
              | (divsel << 20)
              | (bsc << 12)
              | ((rf_enable ? 1u : 0u) << 5)
              | ((uint32_t)power_level << 3)
              | 4u;
    c->reg[5] = (1u << 22)            /* LD pin = digital lock detect        */
              | (3u << 19)            /* reserved, must be 11                */
              | 5u;

    c->vco_khz = vco_khz;
    c->int_val = (uint16_t)n_int;
    c->frac = (uint16_t)frac;
    c->mod = (uint16_t)mod;
    c->rf_div = (uint8_t)div;
    /* exact output in Hz: pfd * (INT + FRAC/MOD) / div */
    uint64_t num = (uint64_t)pfd_khz * 1000u * ((uint64_t)n_int * mod + frac);
    c->actual_hz = (uint32_t)(num / ((uint64_t)mod * div));
    return 0;
}

static uint32_t s_shadow[6];             /* what the chip currently holds */

static void write_reg(const adf4351_cfg_t *c, int i)
{
    plat_adf4351_write(c->reg[i]);
    rf_backend_on_adf_word(c->reg[i]);       /* simulated backend "listens" to the SPI bus */
    s_shadow[i] = c->reg[i];
}

void adf4351_program(const adf4351_cfg_t *c)
{
    for (int i = 5; i >= 0; i--) write_reg(c, i);
}

void adf4351_program_changed(const adf4351_cfg_t *c)
{
    for (int i = 5; i >= 1; i--)
        if (c->reg[i] != s_shadow[i]) write_reg(c, i);
    write_reg(c, 0);
}

int adf4351_wait_lock(uint32_t timeout_us)
{
    for (uint32_t t = 0; t <= timeout_us; t += 10) {
        if (rf_backend_lock_detect()) return 1;
        plat_delay_us(10);
    }
    return 0;
}

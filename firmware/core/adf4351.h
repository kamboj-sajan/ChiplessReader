/* adf4351.h - ADF4351 wideband synthesizer: register calculation + programming. */
#ifndef ADF4351_H
#define ADF4351_H

#include <stdint.h>

typedef struct {
    uint32_t reg[6];        /* R0..R5 as written to the chip          */
    uint32_t vco_khz;       /* VCO frequency                          */
    uint16_t int_val;       /* N-counter integer part                 */
    uint16_t frac, mod;     /* N-counter fractional part FRAC/MOD     */
    uint8_t  rf_div;        /* output divider 1..64                   */
    uint32_t actual_hz;     /* exact output frequency after rounding  */
} adf4351_cfg_t;

/* Compute registers for an output frequency. power_level 0..3 = -4/-1/+2/+5 dBm.
 * Returns 0 on success, -1 if the frequency is outside 35 MHz .. 4.4 GHz. */
int  adf4351_calc(uint32_t out_khz, uint8_t power_level, int rf_enable, adf4351_cfg_t *cfg);

/* Write R5 -> R0 over SPI (R0 last: starts VCO band selection). */
void adf4351_program(const adf4351_cfg_t *cfg);

/* Write only the registers that differ from the last write, then R0, which latches the
 * double-buffered values. Used between sweep points, where only INT/FRAC/MOD change. */
void adf4351_program_changed(const adf4351_cfg_t *cfg);

/* Poll the LD pin until locked or timeout. Returns 1 if locked. */
int  adf4351_wait_lock(uint32_t timeout_us);

#endif

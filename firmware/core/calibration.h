/*
 * calibration.h - the RF chain numbers used to turn AD8302 voltages into dBm.
 *
 * g_cal starts from the datasheet values in app_config.h. The Mac app can overwrite it
 * (SET_CAL) with measured values and store it in flash (NV_SAVE).
 */
#ifndef CALIBRATION_H
#define CALIBRATION_H

#include <stdint.h>

typedef struct {
    float tx_filter_il_db;      /* ADF4351 -> PA input                     */
    float pa_trim_db;           /* added to the MAX2235 datasheet curve    */
    float coupler_db;           /* PA output -> coupled port               */
    float coupler_thru_db;      /* PA output -> TX antenna                 */
    float atten_il_db;          /* PE4312 loss at its 0 dB setting         */
    float lna_gain_db;          /* HMC8410                                 */
    float rx_filter_il_db;      /* LNA -> AD8302 INPB                      */
    float vmag_center_mv;       /* VMAG when INPA = INPB                   */
    float vmag_slope_mv_db;     /* AD8302 magnitude slope                  */
    float vphs_center_mv;       /* VPHS at 90 degrees                      */
    float vphs_slope_mv_deg;    /* AD8302 phase slope                      */
    float rssi_trim_db;         /* added to the reported RSSI              */
} cal_t;

extern cal_t g_cal;

void  cal_defaults(void);

/* ADF4351 output level for a setting 0..3: -4, -1, +2, +5 dBm */
float cal_level_dbm(uint8_t level);

/* MAX2235 output for an input level, from its "output power vs input power" curve at
 * VCC = 3.6 V. The PA compresses: the 9 dB range of the ADF4351 becomes about 3 dB here. */
float cal_max2235_pout_dbm(float pin_dbm);

/* PA output level for a TX setting (uses g_cal); pa_en = 0 gives the shutdown leakage */
float cal_pa_out_dbm(uint8_t level, int pa_en);
/* level at the TX antenna */
float cal_tx_dbm(uint8_t level, int pa_en);
/* reference level at AD8302 INPA for a PE4312 setting in 0.5 dB steps */
float cal_inpa_dbm(uint8_t level, int pa_en, uint8_t atten_half_db);
/* smallest PE4312 setting that keeps INPA at or below the AD8302's 0 dBm input limit */
uint8_t cal_min_atten_half_db(uint8_t level, int pa_en);

#endif

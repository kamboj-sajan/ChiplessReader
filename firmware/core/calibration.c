/* calibration.c - RF chain level calculations. See calibration.h. */
#include <math.h>
#include "calibration.h"
#include "app_config.h"

cal_t g_cal;

void cal_defaults(void)
{
    g_cal.tx_filter_il_db   = CAL_TX_FILTER_IL_DB;
    g_cal.pa_trim_db        = 0.0f;
    g_cal.coupler_db        = CAL_COUPLER_DB;
    g_cal.coupler_thru_db   = CAL_COUPLER_THRU_DB;
    g_cal.atten_il_db       = CAL_ATTEN_IL_DB;
    g_cal.lna_gain_db       = CAL_LNA_GAIN_DB;
    g_cal.rx_filter_il_db   = CAL_RX_FILTER_IL_DB;
    g_cal.vmag_center_mv    = AD8302_VCP_MV;
    g_cal.vmag_slope_mv_db  = AD8302_MAG_MV_PER_DB;
    g_cal.vphs_center_mv    = AD8302_VCP_MV;
    g_cal.vphs_slope_mv_deg = AD8302_PHS_MV_PER_DEG;
    g_cal.rssi_trim_db      = 0.0f;
}

float cal_level_dbm(uint8_t level)
{
    static const float k_dbm[4] = { -4.0f, -1.0f, 2.0f, 5.0f };
    return k_dbm[level & 3];
}

/* Points read from the MAX2235 datasheet graph "Output Power vs. Input Power", VCC = +3.6 V. */
float cal_max2235_pout_dbm(float pin)
{
    static const float k_pin[]  = { -20.0f, -15.0f, -10.0f, -5.0f,  0.0f,  5.0f,  7.0f };
    static const float k_pout[] = {   4.0f,  12.0f,  21.5f, 27.0f, 29.2f, 30.2f, 30.2f };
    const int n = (int)(sizeof k_pin / sizeof k_pin[0]);
    if (pin <= k_pin[0]) return k_pout[0] + (pin - k_pin[0]);
    if (pin >= k_pin[n - 1]) return k_pout[n - 1];
    for (int i = 1; i < n; i++) {
        if (pin <= k_pin[i]) {
            float t = (pin - k_pin[i - 1]) / (k_pin[i] - k_pin[i - 1]);
            return k_pout[i - 1] + t * (k_pout[i] - k_pout[i - 1]);
        }
    }
    return k_pout[n - 1];
}

float cal_pa_out_dbm(uint8_t level, int pa_en)
{
    float pin = cal_level_dbm(level) - g_cal.tx_filter_il_db;
    if (!pa_en) return pin - CAL_PA_OFF_ISOLATION_DB;
    return cal_max2235_pout_dbm(pin) + g_cal.pa_trim_db;
}

float cal_tx_dbm(uint8_t level, int pa_en)
{
    return cal_pa_out_dbm(level, pa_en) - g_cal.coupler_thru_db;
}

float cal_inpa_dbm(uint8_t level, int pa_en, uint8_t atten_half_db)
{
    return cal_pa_out_dbm(level, pa_en) - g_cal.coupler_db - g_cal.atten_il_db - atten_half_db * 0.5f;
}

uint8_t cal_min_atten_half_db(uint8_t level, int pa_en)
{
    float excess = cal_inpa_dbm(level, pa_en, 0) - AD8302_INPUT_MAX_DBM;
    if (excess <= 0.0f) return 0;
    int half = (int)ceilf(excess * 2.0f);
    return (uint8_t)(half > 63 ? 63 : half);
}

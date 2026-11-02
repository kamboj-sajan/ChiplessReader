/* reader.h - reader engine: configuration, RF front-end control, sweep, tag decoding. */
#ifndef READER_H
#define READER_H

#include <stdint.h>
#include "app_config.h"
#include "adf4351.h"

/*
 * The tag profile: what the reader has to know about the tags it reads, because a chipless
 * tag cannot announce any of this itself. Which frequencies to sweep, where each bit sits,
 * how fast to read and how to decide a bit. The tags and the reader must agree on it.
 */
typedef struct {
    char     name[PROFILE_NAME_LEN];
    uint32_t sweep_start_khz, sweep_stop_khz, sweep_step_khz;
    uint16_t settle_us;
    uint8_t  averages;
    uint16_t threshold_x10;     /* notch depth for bit '1', dB x10            */
    uint16_t phase_thr_x10;     /* phase swing that confirms a notch, deg x10 (0 = ignore phase) */
    uint16_t auto_interval_ms;  /* read rate in AUTO mode                     */
    uint8_t  max_bit_errors;    /* differing bits allowed in a database match */
    uint8_t  n_bits;
    uint32_t bit_khz[MAX_TAG_BITS];
} reader_profile_t;

typedef struct {
    reader_profile_t profile;

    /* RF configuration (set by the SDK) */
    uint32_t lo_khz;
    uint8_t  tx_level;          /* 0..3 = -4/-1/+2/+5 dBm ADF4351 output */
    uint8_t  pa_en;
    uint8_t  ref_atten;         /* PE4312, 0.5 dB steps (0..63)          */
    uint8_t  mode;              /* 0 = response, 1 = auto                */
    uint8_t  carrier;           /* 1 = hold the PA on at the LO (for a spectrum analyser) */

    /* live state */
    uint8_t  pll_locked;
    uint8_t  bg_valid;
    uint8_t  nv_loaded;         /* settings came from flash at boot      */
    adf4351_cfg_t adf;          /* last programmed synthesizer settings  */

    /* statistics */
    uint32_t frames_ok, frames_err, reads, tags_found;
} reader_state_t;

extern reader_state_t g_rs;

/* AD8302 input and output conditions, reported with every measurement */
enum {
    RF_INPA_HIGH = 0x01,        /* reference above the 0 dBm input limit */
    RF_INPA_LOW  = 0x02,        /* reference below the -60 dBm limit     */
    RF_INPB_HIGH = 0x04,        /* echo above the 0 dBm input limit      */
    RF_INPB_LOW  = 0x08,        /* echo below the -60 dBm limit          */
    RF_VMAG_CLIP = 0x10,        /* VMAG at a rail: outside +/-30 dB      */
};

typedef struct {
    uint16_t adc_mag, adc_phs;  /* raw 12-bit ADC counts                 */
    uint16_t vmag_mv, vphs_mv;
    float    gain_db;           /* AD8302: P(INPA) - P(INPB)             */
    float    phase_deg;         /* |phase difference|                    */
    float    p_ref_dbm;         /* estimated P(INPA) from calibration    */
    float    p_rx_dbm;          /* derived P(INPB)                       */
    float    rssi_dbm;          /* received power referred to RX antenna */
    int      clipped;           /* VMAG at a rail: outside +/-30 dB      */
    uint8_t  flags;             /* RF_* above                            */
} meas_t;

typedef struct {
    uint32_t seq;
    uint8_t  found;
    uint8_t  n_bits;
    uint32_t id;                /* bit k = resonator k (lowest frequency = bit 0) */
    int16_t  rssi_x10;          /* dBm x10, band average at RX antenna   */
    uint16_t phase_x10;         /* deg x10 at the deepest notch          */
    int16_t  margin_x10;        /* min |depth - threshold|, dB x10       */
    uint16_t sweep_ms;
    uint16_t points;
    uint8_t  bg_used;
    uint16_t clipped;
    uint16_t unlocked;
    int16_t  depth_x10[MAX_TAG_BITS];
    int16_t  swing_x10[MAX_TAG_BITS];   /* phase swing across each bit, deg x10 */
    /* database lookup */
    uint8_t  matched;
    uint8_t  bit_errors;
    int16_t  db_index;          /* -1 = not in the database              */
    char     name[TAGDB_NAME_LEN];
} tag_report_t;

extern tag_report_t g_last_report;

/* result of reader_auto_level() */
typedef struct {
    uint8_t  old_atten, new_atten;      /* 0.5 dB steps                    */
    float    gain_min_db, gain_max_db;  /* AD8302 gain over the last sweep */
    float    inpa_dbm;
    uint16_t clipped;
    uint8_t  flags;
    uint8_t  iterations;
} auto_level_t;

void reader_init(void);
void reader_defaults(void);
/* evenly spaced bit cells: f_k = start + (k + 1/2) * (stop - start) / n */
void reader_layout_bits(reader_profile_t *p, uint8_t n_bits, uint32_t start_khz, uint32_t stop_khz);

/* front-end control; each returns 0 or a protocol status code */
int  reader_set_lo(uint32_t khz);                 /* programs ADF4351, waits for lock */
void reader_apply_tx_power(void);
void reader_apply_atten(void);
void reader_set_carrier(int on);

void reader_measure(meas_t *m);                   /* at the current LO, PA must be on */
void reader_measure_once(meas_t *m);              /* turns the PA on for the reading  */
int  reader_sweep(void);                          /* fills the sweep buffers          */
int  reader_capture_background(void);
void reader_clear_background(void);
int  reader_read_tag(tag_report_t *r);            /* sweep + decode + database lookup */

/* calibration */
int  reader_auto_level(auto_level_t *res);        /* centres the AD8302 on the last sweep */

uint16_t reader_sweep_points(void);
/* last sweep, per point: received level relative to reference (dB x100), |phase| (deg x10),
 * background (dB x100, or INT16_MIN if none) */
void reader_sweep_point(uint16_t i, int16_t *rx_x100, uint16_t *ph_x10, int16_t *bg_x100);
uint32_t reader_last_sweep_start(void);
uint32_t reader_last_sweep_step(void);

uint16_t tag_report_serialize(const tag_report_t *r, uint8_t *out);
float    reader_tx_power_dbm(void);               /* calibrated TX power at antenna  */

#endif

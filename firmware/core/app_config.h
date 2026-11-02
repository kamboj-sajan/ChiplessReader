/*
 * app_config.h - build-time constants for the chipless RFID reader firmware.
 *
 * Everything that depends on the physical RF front-end lives here so it can be
 * re-calibrated in one place once the real board is measured. RF chain values are the
 * datasheet numbers for the parts in the block diagram (the source is named next to each),
 * not measurements. At run time they live in g_cal (calibration.h), which the Mac app can
 * change and store in flash without rebuilding the firmware.
 */
#ifndef APP_CONFIG_H
#define APP_CONFIG_H

#define FW_VERSION_MAJOR        0
#define FW_VERSION_MINOR        3
#define HW_REVISION             1          /* 1 = STM32F4DISCOVERY + module bench setup */
#define READER_MODEL            "CHIPLESS-R1"

/* ---- Protocol ----------------------------------------------------------- */
#define PROTO_SYNC              0xA5
#define PROTO_MAX_LEN           1023       /* LEN field: CMD..CRC inclusive           */
#define PROTO_MAX_PAYLOAD       (PROTO_MAX_LEN - 4)
#define PROTO_INTERBYTE_TIMEOUT_MS 200     /* partial frame is dropped after this     */

/* ---- Sweep / decode limits ---------------------------------------------- */
#define MAX_SWEEP_POINTS        512
#define MAX_TAG_BITS            16
#define PROFILE_NAME_LEN        16

/* ---- Tag database (stored on the STM32) ---------------------------------- */
#define TAGDB_CAPACITY          64
#define TAGDB_NAME_LEN          16

/* ---- ADF4351 synthesizer ------------------------------------------------ */
#define ADF_REF_KHZ             25000      /* module crystal - CHECK your module      */
#define ADF_R_COUNTER           1          /* PFD = REF / R = 25 MHz                  */
#define ADF_MIN_KHZ             35000
#define ADF_MAX_KHZ             4400000
#define ADF_LOCK_TIMEOUT_US     5000

/* ---- RF chain calibration: datasheet defaults (see calibration.c for g_cal) --- */
/* LFCN-1000+: 0.30 dB at 500 MHz, 0.80 dB at 1000 MHz -> about 0.65 dB at 865 MHz    */
#define CAL_TX_FILTER_IL_DB     0.65f
/* X3C09F1-20S: 19.7 +/-0.5 dB coupling, 0.05 dB max main-line loss (869-894 MHz row) */
#define CAL_COUPLER_DB          19.7f
#define CAL_COUPLER_THRU_DB     0.05f
/* PE4312: 1.3 dB typical insertion loss below 1 GHz, at the 0 dB setting             */
#define CAL_ATTEN_IL_DB         1.3f
/* HMC8410: 19.5 dB typical gain, 0.01-3 GHz                                          */
#define CAL_LNA_GAIN_DB         19.5f
/* LFCN-1000+ (0.65 dB) + HFCN-650+ (0.90 dB at 850 MHz)                              */
#define CAL_RX_FILTER_IL_DB     1.55f
/* MAX2235: 48 dB typical off-isolation with SHDN low                                 */
#define CAL_PA_OFF_ISOLATION_DB 48.0f
/* MAX2235 auto-ramp: with the 0.068 uF ramp capacitor from the datasheet circuit the
 * rise time to +30 dBm is about 600 us. Wait this long after enabling before measuring. */
#define PA_RAMP_US              1000
/* PE4312: 800 ns maximum switching time                                              */
#define ATTEN_SETTLE_US         2

/* ---- AD8302 + STM32 ADC ---------------------------------------------------- */
#define AD8302_VCP_MV           900.0f     /* VMAG at equal levels, VPHS at 90 deg    */
#define AD8302_MAG_MV_PER_DB    28.7f      /* datasheet slope at 900 MHz (nominal is 30) */
#define AD8302_PHS_MV_PER_DEG   10.1f      /* datasheet slope at 900 MHz              */
#define AD8302_VMAG_MIN_MV      30.0f      /* -30 dB rail                             */
#define AD8302_VMAG_MAX_MV      1770.0f    /* treat the last 30 mV before +30 dB as clipped */
#define AD8302_INPUT_MAX_DBM    0.0f       /* specified input range in 50 ohm          */
#define AD8302_INPUT_MIN_DBM    (-60.0f)
#define ADC_VREF_MV             3000       /* STM32F4DISCOVERY VDDA ~ 3.0 V           */
#define ADC_FULL_SCALE          4095       /* 12-bit ADC                              */

/* ---- Tag format defaults: 10 bits across 860-865 MHz ----------------------- */
#define BAND_START_KHZ          860000
#define BAND_STOP_KHZ           865000
#define DEF_N_BITS              10
#define DEF_PROFILE_NAME        "10-bit 860-865"

/* ---- Defaults ------------------------------------------------------------- */
#define DEF_LO_KHZ              862500     /* band centre                             */
#define DEF_SWEEP_START_KHZ     BAND_START_KHZ
#define DEF_SWEEP_STOP_KHZ      BAND_STOP_KHZ
#define DEF_SWEEP_STEP_KHZ      25         /* 201 points, 20 per bit cell             */
#define DEF_TX_LEVEL            3          /* +5 dBm ADF4351 output                   */
#define DEF_PA_EN               1
#define DEF_REF_ATTEN_HALF_DB   48         /* 24 dB, the value noted on the block diagram */
#define DEF_SETTLE_US           200
#define DEF_AVERAGES            8
#define DEF_THRESHOLD_X10       60         /* 6.0 dB notch = bit '1'                  */
#define DEF_PHASE_THR_X10       150        /* 15 deg phase swing confirms the notch   */
#define DEF_MAX_BIT_ERRORS      0          /* database match must be exact            */
#define DEF_AUTO_INTERVAL_MS    250

#endif /* APP_CONFIG_H */

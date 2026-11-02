/*
 * rf_backend.h - where the measurements come from.
 *
 *   RF_BACKEND_SIM (rf_sim.c): a model of the whole RF chain + chipless tag. It decodes the
 *       real ADF4351 / PE4312 words the drivers put on the SPI bus, computes what the AD8302
 *       would output, and returns 12-bit ADC counts - so every line of firmware above this
 *       layer runs exactly as it will with hardware.
 *   RF_BACKEND_HW  (rf_hw.c): reads the LD pin and the ADC channels wired to VMAG / VPHS.
 *
 * Select with -DRF_BACKEND_SIM or -DRF_BACKEND_HW.
 */
#ifndef RF_BACKEND_H
#define RF_BACKEND_H

#include <stdint.h>

void        rf_backend_init(void);
const char *rf_backend_name(void);
int         rf_backend_is_sim(void);

/* the drivers tell the backend what they put on the control lines */
void rf_backend_on_adf_word(uint32_t word);
void rf_backend_on_pe4312(uint8_t word6);
void rf_backend_on_pa(int on);

int  rf_backend_lock_detect(void);
void rf_backend_read_adc(uint16_t *vmag_counts, uint16_t *vphs_counts);
/* first boot: the simulated backend fills the tag database with its own tags */
void rf_backend_seed_tagdb(void);

/* ---- simulation controls (return -1 / 0 on the hardware backend) ---- */
#define SIM_MAX_TAGS 8
typedef struct {
    char     name[12];
    uint8_t  n_bits;            /* tag format: 1 single, 2 double, 10 ten-bit      */
    uint32_t code;              /* bit k = 1: resonator present at bit frequency k */
} sim_tag_t;

typedef struct {
    int8_t   tag_index;         /* -1 = no tag in front of the antennas            */
    uint16_t distance_cm;       /* tag distance from the antennas                  */
    uint16_t noise_x100;        /* AD8302 magnitude noise, dB rms x100             */
    uint16_t q;                 /* resonator loaded Q                              */
} sim_params_t;

int              sim_set(const sim_params_t *p);           /* 0 ok, -1 not sim, -2 range */
int              sim_get(sim_params_t *p);
int              sim_tag_count(void);
const sim_tag_t *sim_tag(int i);
uint32_t         sim_bit_khz(int k, int n_bits);           /* physical resonance of bit k */

#endif

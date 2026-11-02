/* rf_hw.c - real hardware backend (RF_BACKEND_HW): LD pin + AD8302 via the ADC. */
#include "rf_backend.h"

#if defined(RF_BACKEND_HW)

#include "platform.h"

void        rf_backend_init(void) {}
const char *rf_backend_name(void) { return "HW"; }
int         rf_backend_is_sim(void) { return 0; }

void rf_backend_on_adf_word(uint32_t word) { (void)word; }
void rf_backend_on_pe4312(uint8_t word6)   { (void)word6; }
void rf_backend_on_pa(int on)              { (void)on; }

int  rf_backend_lock_detect(void) { return plat_adf4351_lock_detect(); }
void rf_backend_read_adc(uint16_t *vmag, uint16_t *vphs) { plat_adc_read(vmag, vphs); }
void rf_backend_seed_tagdb(void) {}

int              sim_set(const sim_params_t *p) { (void)p; return -1; }
int              sim_get(sim_params_t *p) { (void)p; return -1; }
int              sim_tag_count(void) { return 0; }
const sim_tag_t *sim_tag(int i) { (void)i; return 0; }
uint32_t         sim_bit_khz(int k, int n_bits) { (void)k; (void)n_bits; return 0; }

#endif

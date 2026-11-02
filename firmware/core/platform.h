/*
 * platform.h - the only functions the portable core needs from the platform.
 *
 * Two implementations exist:
 *   firmware/stm32/Src/platform_stm32.c - STM32F407 (HAL, USB CDC, SPI2, ADC1+ADC2, flash, ITM/SWV)
 *   firmware/host/main_host.c         - macOS/Linux "virtual reader" (pty, stdout)
 */
#ifndef PLATFORM_H
#define PLATFORM_H

#include <stdint.h>

/* time */
uint32_t plat_millis(void);
void     plat_delay_us(uint32_t us);

/* command link to the SDK (USB CDC on the board, pty on the host) */
void     plat_link_write(const uint8_t *data, uint16_t len);

/* debug console (SWV ITM on the board, stdout on the host) */
void     plat_console_write(const char *s, int len);

/* RF front-end control lines */
void     plat_adf4351_write(uint32_t word);   /* 32-bit SPI word + LE pulse           */
int      plat_adf4351_lock_detect(void);      /* LD pin level                         */
void     plat_pe4312_write(uint8_t word6);    /* 6-bit attenuation word + LE pulse    */
void     plat_pa_enable(int on);              /* MAX2235 SHDN pin                     */

/* AD8302 outputs through the 12-bit ADCs, sampled at the same instant: VMAG on ADC1, VPHS on
 * ADC2 (only used by the hardware backend) */
void     plat_adc_read(uint16_t *vmag_counts, uint16_t *vphs_counts);
/* ADC reference (VDDA) in mV - measured with VREFINT on the STM32, nominal on the host */
uint16_t plat_adc_vref_mv(void);

/* non-volatile storage for one image: flash sector on the STM32, a file on the host.
 * Each returns 0, or -1 on failure. */
int      plat_nv_read(void *dst, uint32_t len);
int      plat_nv_write(const void *src, uint32_t len);

/* status LEDs: 0 green, 1 orange, 2 red, 3 blue */
void     plat_led(int led, int on);

/* 96-bit unique device ID */
void     plat_get_uid(uint8_t uid[12]);

/* soft reset (host: re-initialise state) */
void     plat_reset(void);

#endif /* PLATFORM_H */

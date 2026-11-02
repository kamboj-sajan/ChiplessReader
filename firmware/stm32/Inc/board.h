/*
 * board.h - STM32F407G-DISC1 (STM32F4DISCOVERY, tested target revision MB997E) pin map.
 *
 * MB997D/E notes (UM1472):
 *   - The 8 MHz HSE clock comes from the ST-LINK's MCO output (HSE *bypass*), not from a crystal.
 *     main.c tries bypass first and falls back to crystal mode, so older boards work too.
 *   - SWO (PB3) is NOT connected to the ST-LINK by default (solder bridge SB12 open), so the
 *     SWV console needs SB12 closed. Without soldering, use Live Expressions (g_console) or
 *     USART2 (PA2) - see README "Demo B".
 *   - On-board parts to avoid: IIS2DLPC accelerometer (SPI1 PA5-7, PE3), WM8904 audio codec
 *     (I2C1 PB6/PB9, I2S3 PA4/PC7/PC10/PC12, PD4), MP45DT02 mic (PB10, PC3), USB (PA9-12,
 *     PC0, PD5), SWD (PA13/14), button PA0. All pins below are "free I/O" in UM1472 Table 7.
 *
 *   Signal                  Pin     Header    Direction   Goes to
 *   ---------------------   -----   -------   ---------   ----------------------------------
 *   SPI2 SCK                PB13    P1        out (AF5)   ADF4351 CLK  + PE4312 Clock
 *   SPI2 MOSI               PB15    P1        out (AF5)   ADF4351 DATA + PE4312 Data
 *   ADF4351 LE              PB12    P1        out         ADF4351 LE
 *   ADF4351 CE              PE9     P2        out         ADF4351 CE (high = chip enabled)
 *   ADF4351 LD              PE10    P2        in          ADF4351 LD (high = PLL locked)
 *   PE4312 LE               PE7     P2        out         PE4312 LE
 *   PA enable               PE8     P2        out         MAX2235 SHDN (high = on)
 *   AD8302 VMAG             PA1     P1        analog      ADC1_IN1 (ADC1 in the block diagram)
 *   AD8302 VPHS             PB1     P1        analog      ADC2_IN9 (ADC2 in the block diagram)
 *   Debug console TX        PA2     P1 pin 14 out (AF7)   USART2 TX, 115200 8N1 (optional)
 *   LEDs                    PD12..15                      green / orange / red / blue
 *   USB CDC (command link)  PA11/12           micro-USB CN5
 *   SWO (debug console)     PB3               only if SB12 is closed
 *
 * Module settings the firmware relies on (from the datasheets):
 *   PE4312   P/S = HIGH selects the serial interface. Its power-up state then comes from the C0.5..C16
 *            inputs: strap them for a high attenuation, because INPA reaches about +9 dBm at 0 dB.
 *   AD8302   VMAG shorted to MSET and VPHS shorted to PSET (measurement mode), inputs AC-coupled with
 *            a 52.3 ohm shunt to ground. VDD 2.7-5.5 V; the outputs stay below 1.8 V, inside the ADC range.
 *   MAX2235  VCC 3.6 V for the +30 dBm curve used in the calibration. GC unconnected (gain at maximum).
 *            RAMP capacitor 0.068 uF; PA_RAMP_US in app_config.h assumes this value.
 *   HMC8410  VDD 5 V with VGG1 adjusted for 65 mA, as in its datasheet.
 */
#ifndef BOARD_H
#define BOARD_H

#include "stm32f4xx_hal.h"

#define ADF_LE_PORT     GPIOB
#define ADF_LE_PIN      GPIO_PIN_12
#define ADF_CE_PORT     GPIOE
#define ADF_CE_PIN      GPIO_PIN_9
#define ADF_LD_PORT     GPIOE
#define ADF_LD_PIN      GPIO_PIN_10
#define PE4312_LE_PORT  GPIOE
#define PE4312_LE_PIN   GPIO_PIN_7
#define PA_EN_PORT      GPIOE
#define PA_EN_PIN       GPIO_PIN_8
#define LED_PORT        GPIOD
#define LED_GREEN_PIN   GPIO_PIN_12
#define LED_ORANGE_PIN  GPIO_PIN_13
#define LED_RED_PIN     GPIO_PIN_14
#define LED_BLUE_PIN    GPIO_PIN_15

#define ADC_CH_VMAG     ADC_CHANNEL_1   /* PA1 */
#define ADC_CH_VPHS     ADC_CHANNEL_9   /* PB1 */

/* Flash sector kept for the settings, calibration and tag database (nvstore.c). The linker script
 * keeps code out of it. A 16 KB sector erases in well under a second; the 128 KB sectors take 1-2 s,
 * and the CPU stalls for the whole erase. */
#define NV_FLASH_SECTOR FLASH_SECTOR_1
#define NV_FLASH_ADDR   0x08004000u
#define NV_FLASH_SIZE   (16u * 1024u)

/* Debug console outputs (all enabled by default; each is harmless if nothing listens):
 *   SWV/ITM  - STM32CubeIDE "SWV ITM Data Console" (needs SB12 closed on MB997D/E)
 *   USART2   - PA2, 115200 8N1, to a 3.3 V USB-serial adapter or the ST-LINK VCP
 *   g_console - RAM buffer of the latest lines, visible in CubeIDE Live Expressions */
#define CONSOLE_ITM     1
#define CONSOLE_UART2   1
#define CONSOLE_LINES   16
#define CONSOLE_WIDTH   120

extern SPI_HandleTypeDef  hspi2;
extern ADC_HandleTypeDef  hadc1;
extern ADC_HandleTypeDef  hadc2;
extern UART_HandleTypeDef huart2;
extern const char        *g_clock_source;

/* measures VDDA through VREFINT; call once while ADC1 is still in independent mode */
void board_adc_measure_vdda(void);

#endif

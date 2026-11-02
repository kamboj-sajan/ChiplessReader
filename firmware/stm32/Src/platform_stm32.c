/* platform_stm32.c - implements core/platform.h on the STM32F4DISCOVERY. */
#include <string.h>
#include "board.h"
#include "usbd_cdc_if.h"
#include "platform.h"
#include "app_config.h"

uint32_t plat_millis(void) { return HAL_GetTick(); }

void plat_delay_us(uint32_t us)
{
    uint32_t start = DWT->CYCCNT;
    uint32_t ticks = us * (SystemCoreClock / 1000000u);
    while ((DWT->CYCCNT - start) < ticks) { }
}

/* ---- command link: USB CDC ---- */
void plat_link_write(const uint8_t *d, uint16_t n)
{
    static uint8_t txbuf[1100];            /* must stay valid until the USB transfer completes */
    if (!CDC_IsConfigured()) return;       /* nobody on the other end */
    uint32_t t0 = HAL_GetTick();
    while (CDC_IsBusy()) {                 /* previous frame still going out */
        if (HAL_GetTick() - t0 > 50) return;   /* host not reading: drop rather than hang */
    }
    if (n > sizeof txbuf) n = sizeof txbuf;
    memcpy(txbuf, d, n);
    CDC_Transmit_FS(txbuf, n);
}

/* ---- debug console ----------------------------------------------------------------------
 * Every line goes to up to three places, so it can be seen in STM32CubeIDE with or without
 * soldering / extra hardware:
 *   1. g_console[]  RAM buffer, newest line first -> add "g_console" in Live Expressions
 *                   (works over plain SWD during a debug session - nothing to solder)
 *   2. SWV ITM      port 0 -> "SWV ITM Data Console" (MB997D/E: needs solder bridge SB12 closed)
 *   3. USART2 TX    PA2, 115200 8N1 -> USB-serial adapter / ST-LINK VCP -> CubeIDE serial console
 */
char              g_console[CONSOLE_LINES][CONSOLE_WIDTH];
volatile uint32_t g_console_count;           /* total lines written */
static char       s_line[CONSOLE_WIDTH];
static int        s_line_len;

static void console_commit_line(void)
{
    memmove(&g_console[1][0], &g_console[0][0], (CONSOLE_LINES - 1) * CONSOLE_WIDTH);
    memcpy(&g_console[0][0], s_line, (size_t)s_line_len);
    g_console[0][s_line_len] = 0;
    s_line_len = 0;
    g_console_count++;
}

void plat_console_write(const char *s, int len)
{
#if CONSOLE_ITM
    for (int i = 0; i < len; i++) ITM_SendChar((uint32_t)(uint8_t)s[i]);
#endif
#if CONSOLE_UART2
    HAL_UART_Transmit(&huart2, (const uint8_t *)s, (uint16_t)len, 50);
#endif
    for (int i = 0; i < len; i++) {
        char c = s[i];
        if (c == '\n') { console_commit_line(); continue; }
        if (c == '\r') continue;
        if (s_line_len < CONSOLE_WIDTH - 1) s_line[s_line_len++] = c;
    }
}

/* also route printf() to SWV, in case you add your own printf calls */
int _write(int file, char *ptr, int len)
{
    (void)file;
    plat_console_write(ptr, len);
    return len;
}

/* ---- ADF4351: 32-bit word, MSB first, latched on LE rising edge ---- */
void plat_adf4351_write(uint32_t w)
{
    uint8_t b[4] = { (uint8_t)(w >> 24), (uint8_t)(w >> 16), (uint8_t)(w >> 8), (uint8_t)w };
    HAL_GPIO_WritePin(ADF_LE_PORT, ADF_LE_PIN, GPIO_PIN_RESET);
    HAL_SPI_Transmit(&hspi2, b, 4, 10);
    HAL_GPIO_WritePin(ADF_LE_PORT, ADF_LE_PIN, GPIO_PIN_SET);
    plat_delay_us(1);
    HAL_GPIO_WritePin(ADF_LE_PORT, ADF_LE_PIN, GPIO_PIN_RESET);
}

int plat_adf4351_lock_detect(void)
{
    return HAL_GPIO_ReadPin(ADF_LD_PORT, ADF_LD_PIN) == GPIO_PIN_SET;
}

/* ---- PE4312: 6-bit attenuation word, latched on LE ----
 * Datasheet Table 6: C16 is the first bit in (MSB), C0.5 the last. The 8-bit SPI transfer carries
 * 2 padding bits first; they fall out of the 6-bit shift register, leaving C16..C0.5 in place. */
void plat_pe4312_write(uint8_t word6)
{
    uint8_t v = word6 & 0x3F;
    HAL_GPIO_WritePin(PE4312_LE_PORT, PE4312_LE_PIN, GPIO_PIN_RESET);
    HAL_SPI_Transmit(&hspi2, &v, 1, 10);
    HAL_GPIO_WritePin(PE4312_LE_PORT, PE4312_LE_PIN, GPIO_PIN_SET);
    plat_delay_us(1);
    HAL_GPIO_WritePin(PE4312_LE_PORT, PE4312_LE_PIN, GPIO_PIN_RESET);
}

void plat_pa_enable(int on)
{
    HAL_GPIO_WritePin(PA_EN_PORT, PA_EN_PIN, on ? GPIO_PIN_SET : GPIO_PIN_RESET);
}

/* ---- AD8302 VMAG on ADC1, VPHS on ADC2, sampled together (set up in main.c) ---- */
void plat_adc_read(uint16_t *vmag, uint16_t *vphs)
{
    ADC1->SR = 0;
    ADC2->SR = 0;
    ADC1->CR2 |= ADC_CR2_SWSTART;
    const uint32_t t0 = DWT->CYCCNT, limit = 50u * (SystemCoreClock / 1000000u);
    while (!(ADC1->SR & ADC_SR_EOC)) {
        if (DWT->CYCCNT - t0 > limit) break;
    }
    *vmag = (uint16_t)ADC1->DR;
    *vphs = (uint16_t)ADC2->DR;
}

/* VDDA from the internal reference: VREFINT_CAL was measured by ST at VDDA = 3.3 V */
static uint16_t s_vdda_mv = ADC_VREF_MV;

void board_adc_measure_vdda(void)
{
    const uint16_t cal = *(const uint16_t *)0x1FFF7A2Au;
    ADC_ChannelConfTypeDef c = {0};
    c.Channel = ADC_CHANNEL_VREFINT;
    c.Rank = 1;
    c.SamplingTime = ADC_SAMPLETIME_480CYCLES;
    HAL_ADC_ConfigChannel(&hadc1, &c);
    uint32_t sum = 0;
    for (int i = 0; i < 8; i++) {
        HAL_ADC_Start(&hadc1);
        HAL_ADC_PollForConversion(&hadc1, 2);
        sum += HAL_ADC_GetValue(&hadc1);
        HAL_ADC_Stop(&hadc1);
    }
    uint32_t raw = sum / 8;
    if (raw && cal) s_vdda_mv = (uint16_t)(3300u * cal / raw);
}

uint16_t plat_adc_vref_mv(void) { return s_vdda_mv; }

/* ---- settings, calibration and tag database: one image in its own flash sector ---- */
int plat_nv_read(void *dst, uint32_t len)
{
    if (len > NV_FLASH_SIZE) return -1;
    memcpy(dst, (const void *)NV_FLASH_ADDR, len);
    return 0;
}

int plat_nv_write(const void *src, uint32_t len)
{
    if (len > NV_FLASH_SIZE) return -1;
    const uint8_t *p = (const uint8_t *)src;
    FLASH_EraseInitTypeDef e = {0};
    uint32_t sector_error = 0;
    e.TypeErase = FLASH_TYPEERASE_SECTORS;
    e.Sector = NV_FLASH_SECTOR;
    e.NbSectors = 1;
    e.VoltageRange = FLASH_VOLTAGE_RANGE_3;      /* the board runs at 3 V: 32-bit programming */

    HAL_FLASH_Unlock();
    int r = (HAL_FLASHEx_Erase(&e, &sector_error) == HAL_OK) ? 0 : -1;
    for (uint32_t off = 0; r == 0 && off < len; off += 4) {
        uint32_t word = 0xFFFFFFFFu;
        memcpy(&word, p + off, (len - off) < 4 ? (len - off) : 4);
        if (HAL_FLASH_Program(FLASH_TYPEPROGRAM_WORD, NV_FLASH_ADDR + off, word) != HAL_OK) r = -1;
    }
    HAL_FLASH_Lock();
    if (r == 0 && memcmp((const void *)NV_FLASH_ADDR, src, len) != 0) r = -1;
    return r;
}

void plat_led(int led, int on)
{
    static const uint16_t pins[4] = { LED_GREEN_PIN, LED_ORANGE_PIN, LED_RED_PIN, LED_BLUE_PIN };
    if (led < 0 || led > 3) return;
    HAL_GPIO_WritePin(LED_PORT, pins[led], on ? GPIO_PIN_SET : GPIO_PIN_RESET);
}

void plat_get_uid(uint8_t uid[12])
{
    memcpy(uid, (const void *)UID_BASE, 12);
}

void plat_reset(void)
{
    NVIC_SystemReset();
}

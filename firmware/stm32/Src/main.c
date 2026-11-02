/*
 * main.c - STM32F407G-DISC1 (MB997E) entry point for the chipless RFID reader.
 *
 * Clock: 8 MHz HSE -> PLL -> 168 MHz SYSCLK, 48 MHz USB (PLLQ = 7), APB1 42 MHz, APB2 84 MHz.
 * On MB997D/E the 8 MHz comes from the ST-LINK MCO (HSE bypass); older boards have a crystal.
 * Both are tried. IMPORTANT for the SWV console: "Core Clock = 168 MHz" in the debug config.
 */
#include "board.h"
#include "usbd_cdc_if.h"
#include "app.h"
#include "console.h"
#include "platform.h"

SPI_HandleTypeDef  hspi2;
ADC_HandleTypeDef  hadc1;
ADC_HandleTypeDef  hadc2;
UART_HandleTypeDef huart2;
const char        *g_clock_source = "?";

static void GPIO_Init(void);
static void SPI2_Init(void);
static void ADC_Init(void);
static void USART2_Init(void);
static void DWT_Init(void);
void Error_Handler(void);

static HAL_StatusTypeDef start_pll(uint32_t hse_state)
{
    RCC_OscInitTypeDef osc = {0};
    osc.OscillatorType = RCC_OSCILLATORTYPE_HSE;
    osc.HSEState = hse_state;
    osc.PLL.PLLState = RCC_PLL_ON;
    osc.PLL.PLLSource = RCC_PLLSOURCE_HSE;
    osc.PLL.PLLM = 8;
    osc.PLL.PLLN = 336;
    osc.PLL.PLLP = RCC_PLLP_DIV2;   /* 168 MHz */
    osc.PLL.PLLQ = 7;               /* 48 MHz for USB */
    return HAL_RCC_OscConfig(&osc);
}

static void SystemClock_Config(void)
{
    RCC_ClkInitTypeDef clk = {0};

    __HAL_RCC_PWR_CLK_ENABLE();
    __HAL_PWR_VOLTAGESCALING_CONFIG(PWR_REGULATOR_VOLTAGE_SCALE1);

    /* MB997D/E: 8 MHz square wave from the ST-LINK MCO -> bypass mode.
     * MB997B/C: 8 MHz crystal X2 -> oscillator mode. Try bypass first, then crystal. */
    if (start_pll(RCC_HSE_BYPASS) == HAL_OK) {
        g_clock_source = "HSE bypass (8 MHz from ST-LINK MCO)";
    } else {
        RCC_OscInitTypeDef off = {0};
        off.OscillatorType = RCC_OSCILLATORTYPE_HSE;
        off.HSEState = RCC_HSE_OFF;
        off.PLL.PLLState = RCC_PLL_NONE;
        HAL_RCC_OscConfig(&off);
        if (start_pll(RCC_HSE_ON) != HAL_OK) Error_Handler();
        g_clock_source = "HSE crystal (8 MHz X2)";
    }

    clk.ClockType = RCC_CLOCKTYPE_HCLK | RCC_CLOCKTYPE_SYSCLK | RCC_CLOCKTYPE_PCLK1 | RCC_CLOCKTYPE_PCLK2;
    clk.SYSCLKSource = RCC_SYSCLKSOURCE_PLLCLK;
    clk.AHBCLKDivider = RCC_SYSCLK_DIV1;
    clk.APB1CLKDivider = RCC_HCLK_DIV4;
    clk.APB2CLKDivider = RCC_HCLK_DIV2;
    if (HAL_RCC_ClockConfig(&clk, FLASH_LATENCY_5) != HAL_OK) Error_Handler();
}

int main(void)
{
    HAL_Init();
    SystemClock_Config();
    DWT_Init();
    GPIO_Init();
    USART2_Init();
    SPI2_Init();
    ADC_Init();
    MX_USB_DEVICE_Init();

    app_init("USB CDC (micro-USB CN5)");
    console_printf("clock: %s -> SYSCLK %lu MHz, VDDA %u mV\n", g_clock_source,
                   (unsigned long)(SystemCoreClock / 1000000u), plat_adc_vref_mv());

    while (1) {
        app_poll();
    }
}

static void DWT_Init(void)
{
    /* cycle counter for microsecond delays (also enables the trace block used by SWV) */
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT = 0;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
}

static void GPIO_Init(void)
{
    GPIO_InitTypeDef g = {0};
    __HAL_RCC_GPIOA_CLK_ENABLE();
    __HAL_RCC_GPIOB_CLK_ENABLE();
    __HAL_RCC_GPIOD_CLK_ENABLE();
    __HAL_RCC_GPIOE_CLK_ENABLE();
    __HAL_RCC_GPIOH_CLK_ENABLE();

    /* outputs: idle levels first */
    HAL_GPIO_WritePin(LED_PORT, LED_GREEN_PIN | LED_ORANGE_PIN | LED_RED_PIN | LED_BLUE_PIN, GPIO_PIN_RESET);
    HAL_GPIO_WritePin(ADF_LE_PORT, ADF_LE_PIN, GPIO_PIN_RESET);
    HAL_GPIO_WritePin(ADF_CE_PORT, ADF_CE_PIN, GPIO_PIN_SET);
    HAL_GPIO_WritePin(PE4312_LE_PORT, PE4312_LE_PIN, GPIO_PIN_RESET);
    HAL_GPIO_WritePin(PA_EN_PORT, PA_EN_PIN, GPIO_PIN_RESET);

    g.Mode = GPIO_MODE_OUTPUT_PP;
    g.Pull = GPIO_NOPULL;
    g.Speed = GPIO_SPEED_FREQ_LOW;
    g.Pin = LED_GREEN_PIN | LED_ORANGE_PIN | LED_RED_PIN | LED_BLUE_PIN;
    HAL_GPIO_Init(LED_PORT, &g);

    g.Speed = GPIO_SPEED_FREQ_HIGH;
    g.Pin = ADF_LE_PIN;
    HAL_GPIO_Init(ADF_LE_PORT, &g);
    g.Pin = ADF_CE_PIN | PE4312_LE_PIN | PA_EN_PIN;
    HAL_GPIO_Init(GPIOE, &g);

    g.Mode = GPIO_MODE_INPUT;
    g.Pull = GPIO_PULLDOWN;          /* no synthesizer connected -> reads "unlocked" */
    g.Pin = ADF_LD_PIN;
    HAL_GPIO_Init(ADF_LD_PORT, &g);
}

static void SPI2_Init(void)
{
    hspi2.Instance = SPI2;
    hspi2.Init.Mode = SPI_MODE_MASTER;
    hspi2.Init.Direction = SPI_DIRECTION_2LINES;
    hspi2.Init.DataSize = SPI_DATASIZE_8BIT;
    hspi2.Init.CLKPolarity = SPI_POLARITY_LOW;      /* ADF4351 / PE4312 clock data on the rising edge */
    hspi2.Init.CLKPhase = SPI_PHASE_1EDGE;
    hspi2.Init.NSS = SPI_NSS_SOFT;
    hspi2.Init.BaudRatePrescaler = SPI_BAUDRATEPRESCALER_16;   /* 42 MHz / 16 = 2.6 MHz (PE4312 max 10 MHz, ADF4351 max 20 MHz) */
    hspi2.Init.FirstBit = SPI_FIRSTBIT_MSB;
    hspi2.Init.TIMode = SPI_TIMODE_DISABLE;
    hspi2.Init.CRCCalculation = SPI_CRCCALCULATION_DISABLE;
    hspi2.Init.CRCPolynomial = 10;
    if (HAL_SPI_Init(&hspi2) != HAL_OK) Error_Handler();
}

void HAL_SPI_MspInit(SPI_HandleTypeDef *h)
{
    if (h->Instance != SPI2) return;
    GPIO_InitTypeDef g = {0};
    __HAL_RCC_SPI2_CLK_ENABLE();
    __HAL_RCC_GPIOB_CLK_ENABLE();
    g.Pin = GPIO_PIN_13 | GPIO_PIN_15;      /* SCK, MOSI */
    g.Mode = GPIO_MODE_AF_PP;
    g.Pull = GPIO_NOPULL;
    g.Speed = GPIO_SPEED_FREQ_VERY_HIGH;
    g.Alternate = GPIO_AF5_SPI2;
    HAL_GPIO_Init(GPIOB, &g);
}

static void ADC_InitOne(ADC_HandleTypeDef *h, ADC_TypeDef *instance)
{
    h->Instance = instance;
    h->Init.ClockPrescaler = ADC_CLOCK_SYNC_PCLK_DIV4;    /* 84 / 4 = 21 MHz */
    h->Init.Resolution = ADC_RESOLUTION_12B;
    h->Init.ScanConvMode = DISABLE;
    h->Init.ContinuousConvMode = DISABLE;
    h->Init.DiscontinuousConvMode = DISABLE;
    h->Init.ExternalTrigConvEdge = ADC_EXTERNALTRIGCONVEDGE_NONE;
    h->Init.ExternalTrigConv = ADC_SOFTWARE_START;
    h->Init.DataAlign = ADC_DATAALIGN_RIGHT;
    h->Init.NbrOfConversion = 1;
    h->Init.DMAContinuousRequests = DISABLE;
    h->Init.EOCSelection = ADC_EOC_SINGLE_CONV;
    if (HAL_ADC_Init(h) != HAL_OK) Error_Handler();
}

/* ADC1 reads VMAG and ADC2 reads VPHS in dual regular simultaneous mode: a software start on ADC1
 * samples both at the same instant, so magnitude and phase describe the same moment. */
static void ADC_Init(void)
{
    ADC_InitOne(&hadc1, ADC1);
    ADC_InitOne(&hadc2, ADC2);
    board_adc_measure_vdda();

    ADC_ChannelConfTypeDef c = {0};
    c.Rank = 1;
    c.SamplingTime = ADC_SAMPLETIME_84CYCLES;
    c.Channel = ADC_CH_VMAG;
    if (HAL_ADC_ConfigChannel(&hadc1, &c) != HAL_OK) Error_Handler();
    c.Channel = ADC_CH_VPHS;
    if (HAL_ADC_ConfigChannel(&hadc2, &c) != HAL_OK) Error_Handler();

    ADC_MultiModeTypeDef mm = {0};
    mm.Mode = ADC_DUALMODE_REGSIMULT;
    mm.DMAAccessMode = ADC_DMAACCESSMODE_DISABLED;
    mm.TwoSamplingDelay = ADC_TWOSAMPLINGDELAY_5CYCLES;
    if (HAL_ADCEx_MultiModeConfigChannel(&hadc1, &mm) != HAL_OK) Error_Handler();

    __HAL_ADC_ENABLE(&hadc2);
    __HAL_ADC_ENABLE(&hadc1);
    plat_delay_us(5);                   /* ADC stabilisation time */
}

void HAL_ADC_MspInit(ADC_HandleTypeDef *h)
{
    if (h->Instance == ADC2) {
        __HAL_RCC_ADC2_CLK_ENABLE();
        return;
    }
    if (h->Instance != ADC1) return;
    GPIO_InitTypeDef g = {0};
    __HAL_RCC_ADC1_CLK_ENABLE();
    __HAL_RCC_GPIOA_CLK_ENABLE();
    __HAL_RCC_GPIOB_CLK_ENABLE();
    g.Mode = GPIO_MODE_ANALOG;
    g.Pull = GPIO_NOPULL;
    g.Pin = GPIO_PIN_1;                 /* PA1 = VMAG */
    HAL_GPIO_Init(GPIOA, &g);
    g.Pin = GPIO_PIN_1;                 /* PB1 = VPHS */
    HAL_GPIO_Init(GPIOB, &g);
}

static void USART2_Init(void)
{
    huart2.Instance = USART2;
    huart2.Init.BaudRate = 115200;
    huart2.Init.WordLength = UART_WORDLENGTH_8B;
    huart2.Init.StopBits = UART_STOPBITS_1;
    huart2.Init.Parity = UART_PARITY_NONE;
    huart2.Init.Mode = UART_MODE_TX_RX;
    huart2.Init.HwFlowCtl = UART_HWCONTROL_NONE;
    huart2.Init.OverSampling = UART_OVERSAMPLING_16;
    if (HAL_UART_Init(&huart2) != HAL_OK) Error_Handler();
}

void HAL_UART_MspInit(UART_HandleTypeDef *h)
{
    if (h->Instance != USART2) return;
    GPIO_InitTypeDef g = {0};
    __HAL_RCC_USART2_CLK_ENABLE();
    __HAL_RCC_GPIOA_CLK_ENABLE();
    g.Pin = GPIO_PIN_2 | GPIO_PIN_3;    /* PA2 TX, PA3 RX (P1 pins 14 / 13) */
    g.Mode = GPIO_MODE_AF_PP;
    g.Pull = GPIO_PULLUP;
    g.Speed = GPIO_SPEED_FREQ_HIGH;
    g.Alternate = GPIO_AF7_USART2;
    HAL_GPIO_Init(GPIOA, &g);
}

void Error_Handler(void)
{
    __disable_irq();
    HAL_GPIO_WritePin(LED_PORT, LED_RED_PIN, GPIO_PIN_SET);
    while (1) { }
}

/* usbd_conf.c - glue between the ST USB device library and the HAL PCD driver (OTG_FS). */
#include "usbd_conf.h"
#include "usbd_core.h"
#include "usbd_cdc.h"

PCD_HandleTypeDef hpcd_USB_OTG_FS;
void Error_Handler(void);

static USBD_StatusTypeDef to_usbd(HAL_StatusTypeDef s)
{
    switch (s) {
    case HAL_OK:   return USBD_OK;
    case HAL_BUSY: return USBD_BUSY;
    default:       return USBD_FAIL;
    }
}

/* ---- MSP ---- */
void HAL_PCD_MspInit(PCD_HandleTypeDef *h)
{
    if (h->Instance != USB_OTG_FS) return;
    GPIO_InitTypeDef g = {0};
    __HAL_RCC_GPIOA_CLK_ENABLE();
    g.Pin = GPIO_PIN_11 | GPIO_PIN_12;            /* DM, DP */
    g.Mode = GPIO_MODE_AF_PP;
    g.Pull = GPIO_NOPULL;
    g.Speed = GPIO_SPEED_FREQ_VERY_HIGH;
    g.Alternate = GPIO_AF10_OTG_FS;
    HAL_GPIO_Init(GPIOA, &g);
    __HAL_RCC_USB_OTG_FS_CLK_ENABLE();
    HAL_NVIC_SetPriority(OTG_FS_IRQn, 5, 0);
    HAL_NVIC_EnableIRQ(OTG_FS_IRQn);
}

void HAL_PCD_MspDeInit(PCD_HandleTypeDef *h)
{
    if (h->Instance != USB_OTG_FS) return;
    __HAL_RCC_USB_OTG_FS_CLK_DISABLE();
    HAL_GPIO_DeInit(GPIOA, GPIO_PIN_11 | GPIO_PIN_12);
    HAL_NVIC_DisableIRQ(OTG_FS_IRQn);
}

/* ---- PCD -> USBD callbacks ---- */
void HAL_PCD_SetupStageCallback(PCD_HandleTypeDef *h) { USBD_LL_SetupStage((USBD_HandleTypeDef *)h->pData, (uint8_t *)h->Setup); }
void HAL_PCD_DataOutStageCallback(PCD_HandleTypeDef *h, uint8_t ep) { USBD_LL_DataOutStage((USBD_HandleTypeDef *)h->pData, ep, h->OUT_ep[ep].xfer_buff); }
void HAL_PCD_DataInStageCallback(PCD_HandleTypeDef *h, uint8_t ep) { USBD_LL_DataInStage((USBD_HandleTypeDef *)h->pData, ep, h->IN_ep[ep].xfer_buff); }
void HAL_PCD_SOFCallback(PCD_HandleTypeDef *h) { USBD_LL_SOF((USBD_HandleTypeDef *)h->pData); }
void HAL_PCD_ResetCallback(PCD_HandleTypeDef *h)
{
    USBD_LL_SetSpeed((USBD_HandleTypeDef *)h->pData, USBD_SPEED_FULL);
    USBD_LL_Reset((USBD_HandleTypeDef *)h->pData);
}
void HAL_PCD_SuspendCallback(PCD_HandleTypeDef *h) { USBD_LL_Suspend((USBD_HandleTypeDef *)h->pData); }
void HAL_PCD_ResumeCallback(PCD_HandleTypeDef *h) { USBD_LL_Resume((USBD_HandleTypeDef *)h->pData); }
void HAL_PCD_ISOOUTIncompleteCallback(PCD_HandleTypeDef *h, uint8_t ep) { USBD_LL_IsoOUTIncomplete((USBD_HandleTypeDef *)h->pData, ep); }
void HAL_PCD_ISOINIncompleteCallback(PCD_HandleTypeDef *h, uint8_t ep) { USBD_LL_IsoINIncomplete((USBD_HandleTypeDef *)h->pData, ep); }
void HAL_PCD_ConnectCallback(PCD_HandleTypeDef *h) { USBD_LL_DevConnected((USBD_HandleTypeDef *)h->pData); }
void HAL_PCD_DisconnectCallback(PCD_HandleTypeDef *h) { USBD_LL_DevDisconnected((USBD_HandleTypeDef *)h->pData); }

/* ---- USBD low-level interface ---- */
USBD_StatusTypeDef USBD_LL_Init(USBD_HandleTypeDef *pdev)
{
    hpcd_USB_OTG_FS.pData = pdev;
    pdev->pData = &hpcd_USB_OTG_FS;
    hpcd_USB_OTG_FS.Instance = USB_OTG_FS;
    hpcd_USB_OTG_FS.Init.dev_endpoints = 4;
    hpcd_USB_OTG_FS.Init.speed = PCD_SPEED_FULL;
    hpcd_USB_OTG_FS.Init.dma_enable = DISABLE;
    hpcd_USB_OTG_FS.Init.phy_itface = PCD_PHY_EMBEDDED;
    hpcd_USB_OTG_FS.Init.Sof_enable = DISABLE;
    hpcd_USB_OTG_FS.Init.low_power_enable = DISABLE;
    hpcd_USB_OTG_FS.Init.lpm_enable = DISABLE;
    hpcd_USB_OTG_FS.Init.vbus_sensing_enable = DISABLE;   /* PA9 not used for VBUS sensing */
    hpcd_USB_OTG_FS.Init.use_dedicated_ep1 = DISABLE;
    if (HAL_PCD_Init(&hpcd_USB_OTG_FS) != HAL_OK) Error_Handler();

    HAL_PCDEx_SetRxFiFo(&hpcd_USB_OTG_FS, 0x80);
    HAL_PCDEx_SetTxFiFo(&hpcd_USB_OTG_FS, 0, 0x40);
    HAL_PCDEx_SetTxFiFo(&hpcd_USB_OTG_FS, 1, 0x80);
    return USBD_OK;
}

USBD_StatusTypeDef USBD_LL_DeInit(USBD_HandleTypeDef *p) { return to_usbd(HAL_PCD_DeInit(p->pData)); }
USBD_StatusTypeDef USBD_LL_Start(USBD_HandleTypeDef *p) { return to_usbd(HAL_PCD_Start(p->pData)); }
USBD_StatusTypeDef USBD_LL_Stop(USBD_HandleTypeDef *p) { return to_usbd(HAL_PCD_Stop(p->pData)); }
USBD_StatusTypeDef USBD_LL_OpenEP(USBD_HandleTypeDef *p, uint8_t ep, uint8_t type, uint16_t mps)
{ return to_usbd(HAL_PCD_EP_Open(p->pData, ep, mps, type)); }
USBD_StatusTypeDef USBD_LL_CloseEP(USBD_HandleTypeDef *p, uint8_t ep) { return to_usbd(HAL_PCD_EP_Close(p->pData, ep)); }
USBD_StatusTypeDef USBD_LL_FlushEP(USBD_HandleTypeDef *p, uint8_t ep) { return to_usbd(HAL_PCD_EP_Flush(p->pData, ep)); }
USBD_StatusTypeDef USBD_LL_StallEP(USBD_HandleTypeDef *p, uint8_t ep) { return to_usbd(HAL_PCD_EP_SetStall(p->pData, ep)); }
USBD_StatusTypeDef USBD_LL_ClearStallEP(USBD_HandleTypeDef *p, uint8_t ep) { return to_usbd(HAL_PCD_EP_ClrStall(p->pData, ep)); }
uint8_t USBD_LL_IsStallEP(USBD_HandleTypeDef *p, uint8_t ep)
{
    PCD_HandleTypeDef *h = (PCD_HandleTypeDef *)p->pData;
    return (ep & 0x80U) ? h->IN_ep[ep & 0x7FU].is_stall : h->OUT_ep[ep & 0x7FU].is_stall;
}
USBD_StatusTypeDef USBD_LL_SetUSBAddress(USBD_HandleTypeDef *p, uint8_t addr) { return to_usbd(HAL_PCD_SetAddress(p->pData, addr)); }
USBD_StatusTypeDef USBD_LL_Transmit(USBD_HandleTypeDef *p, uint8_t ep, uint8_t *buf, uint32_t size)
{ return to_usbd(HAL_PCD_EP_Transmit(p->pData, ep, buf, size)); }
USBD_StatusTypeDef USBD_LL_PrepareReceive(USBD_HandleTypeDef *p, uint8_t ep, uint8_t *buf, uint32_t size)
{ return to_usbd(HAL_PCD_EP_Receive(p->pData, ep, buf, size)); }
uint32_t USBD_LL_GetRxDataSize(USBD_HandleTypeDef *p, uint8_t ep) { return HAL_PCD_EP_GetRxCount((PCD_HandleTypeDef *)p->pData, ep); }
void USBD_LL_Delay(uint32_t ms) { HAL_Delay(ms); }

/* static allocation for the CDC class handle */
void *USBD_static_malloc(uint32_t size)
{
    static uint32_t mem[(sizeof(USBD_CDC_HandleTypeDef) / 4) + 1];
    (void)size;
    return mem;
}
void USBD_static_free(void *p) { (void)p; }

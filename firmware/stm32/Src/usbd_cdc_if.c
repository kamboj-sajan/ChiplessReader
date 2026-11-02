/* usbd_cdc_if.c - USB CDC (virtual COM port) interface: bytes from the Mac go to app_on_rx(). */
#include "usbd_cdc_if.h"
#include "usbd_core.h"
#include "usbd_desc.h"
#include "app.h"

void Error_Handler(void);

USBD_HandleTypeDef hUsbDeviceFS;

#define RX_SIZE 64
static uint8_t s_rx[RX_SIZE];
static uint8_t s_line_coding[7] = { 0x00, 0xC2, 0x01, 0x00, 0x00, 0x00, 0x08 };  /* 115200 8N1 */

static int8_t cdc_init(void)
{
    USBD_CDC_SetTxBuffer(&hUsbDeviceFS, NULL, 0);
    USBD_CDC_SetRxBuffer(&hUsbDeviceFS, s_rx);
    return USBD_OK;
}

static int8_t cdc_deinit(void) { return USBD_OK; }

static int8_t cdc_control(uint8_t cmd, uint8_t *pbuf, uint16_t length)
{
    (void)length;
    switch (cmd) {
    case CDC_SET_LINE_CODING: memcpy(s_line_coding, pbuf, 7); break;   /* baud is irrelevant for USB */
    case CDC_GET_LINE_CODING: memcpy(pbuf, s_line_coding, 7); break;
    default: break;
    }
    return USBD_OK;
}

/* runs in the USB interrupt: hand the bytes over and re-arm - no parsing here */
static int8_t cdc_receive(uint8_t *buf, uint32_t *len)
{
    app_on_rx(buf, *len);
    USBD_CDC_SetRxBuffer(&hUsbDeviceFS, s_rx);
    USBD_CDC_ReceivePacket(&hUsbDeviceFS);
    return USBD_OK;
}

static int8_t cdc_tx_done(uint8_t *buf, uint32_t *len, uint8_t ep)
{
    (void)buf; (void)len; (void)ep;
    return USBD_OK;
}

USBD_CDC_ItfTypeDef USBD_Interface_fops_FS = { cdc_init, cdc_deinit, cdc_control, cdc_receive, cdc_tx_done };

void MX_USB_DEVICE_Init(void)
{
    if (USBD_Init(&hUsbDeviceFS, &FS_Desc, DEVICE_FS) != USBD_OK) Error_Handler();
    if (USBD_RegisterClass(&hUsbDeviceFS, &USBD_CDC) != USBD_OK) Error_Handler();
    if (USBD_CDC_RegisterInterface(&hUsbDeviceFS, &USBD_Interface_fops_FS) != USBD_OK) Error_Handler();
    if (USBD_Start(&hUsbDeviceFS) != USBD_OK) Error_Handler();
}

int CDC_IsConfigured(void)
{
    return hUsbDeviceFS.dev_state == USBD_STATE_CONFIGURED && hUsbDeviceFS.pClassData != NULL;
}

int CDC_IsBusy(void)
{
    USBD_CDC_HandleTypeDef *h = (USBD_CDC_HandleTypeDef *)hUsbDeviceFS.pClassData;
    return h != NULL && h->TxState != 0;
}

uint8_t CDC_Transmit_FS(uint8_t *buf, uint16_t len)
{
    USBD_CDC_HandleTypeDef *h = (USBD_CDC_HandleTypeDef *)hUsbDeviceFS.pClassData;
    if (h == NULL) return USBD_FAIL;
    if (h->TxState != 0) return USBD_BUSY;
    USBD_CDC_SetTxBuffer(&hUsbDeviceFS, buf, len);
    return USBD_CDC_TransmitPacket(&hUsbDeviceFS);
}

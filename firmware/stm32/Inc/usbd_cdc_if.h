#ifndef USBD_CDC_IF_H
#define USBD_CDC_IF_H
#include "usbd_cdc.h"

extern USBD_HandleTypeDef hUsbDeviceFS;
extern USBD_CDC_ItfTypeDef USBD_Interface_fops_FS;

void    MX_USB_DEVICE_Init(void);
uint8_t CDC_Transmit_FS(uint8_t *buf, uint16_t len);
int     CDC_IsConfigured(void);
int     CDC_IsBusy(void);

#endif

/* usbd_desc.c - USB descriptors. Uses ST's Virtual COM Port VID/PID (0483:5740) so macOS
 * binds its built-in CDC driver and creates /dev/cu.usbmodem<serial>. */
#include "usbd_core.h"
#include "usbd_desc.h"
#include "usbd_conf.h"

#define USBD_VID                0x0483
#define USBD_PID                0x5740
#define USBD_LANGID             0x0409
#define USBD_MANUFACTURER       "Chipless RFID Project"
#define USBD_PRODUCT            "Chipless RFID Reader (CHIPLESS-R1)"
#define USBD_CONFIGURATION      "CDC Config"
#define USBD_INTERFACE          "CDC Interface"
#define USB_SIZ_STRING_SERIAL   0x1A

static uint8_t *dev_desc(USBD_SpeedTypeDef s, uint16_t *len);
static uint8_t *langid_desc(USBD_SpeedTypeDef s, uint16_t *len);
static uint8_t *manuf_desc(USBD_SpeedTypeDef s, uint16_t *len);
static uint8_t *product_desc(USBD_SpeedTypeDef s, uint16_t *len);
static uint8_t *serial_desc(USBD_SpeedTypeDef s, uint16_t *len);
static uint8_t *config_desc(USBD_SpeedTypeDef s, uint16_t *len);
static uint8_t *iface_desc(USBD_SpeedTypeDef s, uint16_t *len);

USBD_DescriptorsTypeDef FS_Desc = {
    dev_desc, langid_desc, manuf_desc, product_desc, serial_desc, config_desc, iface_desc,
};

__ALIGN_BEGIN static uint8_t s_dev[USB_LEN_DEV_DESC] __ALIGN_END = {
    0x12, USB_DESC_TYPE_DEVICE, 0x00, 0x02,   /* USB 2.0 */
    0x02, 0x02, 0x00,                         /* class CDC, subclass ACM, protocol none */
    USB_MAX_EP0_SIZE,
    LOBYTE(USBD_VID), HIBYTE(USBD_VID),
    LOBYTE(USBD_PID), HIBYTE(USBD_PID),
    0x00, 0x02,                               /* device release 2.00 */
    USBD_IDX_MFC_STR, USBD_IDX_PRODUCT_STR, USBD_IDX_SERIAL_STR,
    USBD_MAX_NUM_CONFIGURATION
};

__ALIGN_BEGIN static uint8_t s_langid[USB_LEN_LANGID_STR_DESC] __ALIGN_END = {
    USB_LEN_LANGID_STR_DESC, USB_DESC_TYPE_STRING, LOBYTE(USBD_LANGID), HIBYTE(USBD_LANGID)
};

__ALIGN_BEGIN static uint8_t s_str[USBD_MAX_STR_DESC_SIZ] __ALIGN_END;
__ALIGN_BEGIN static uint8_t s_serial[USB_SIZ_STRING_SERIAL] __ALIGN_END = { USB_SIZ_STRING_SERIAL, USB_DESC_TYPE_STRING };

static uint8_t *dev_desc(USBD_SpeedTypeDef s, uint16_t *len) { (void)s; *len = sizeof s_dev; return s_dev; }
static uint8_t *langid_desc(USBD_SpeedTypeDef s, uint16_t *len) { (void)s; *len = sizeof s_langid; return s_langid; }
static uint8_t *manuf_desc(USBD_SpeedTypeDef s, uint16_t *len) { (void)s; USBD_GetString((uint8_t *)USBD_MANUFACTURER, s_str, len); return s_str; }
static uint8_t *product_desc(USBD_SpeedTypeDef s, uint16_t *len) { (void)s; USBD_GetString((uint8_t *)USBD_PRODUCT, s_str, len); return s_str; }
static uint8_t *config_desc(USBD_SpeedTypeDef s, uint16_t *len) { (void)s; USBD_GetString((uint8_t *)USBD_CONFIGURATION, s_str, len); return s_str; }
static uint8_t *iface_desc(USBD_SpeedTypeDef s, uint16_t *len) { (void)s; USBD_GetString((uint8_t *)USBD_INTERFACE, s_str, len); return s_str; }

static void int_to_unicode(uint32_t v, uint8_t *p, uint8_t n)
{
    for (uint8_t i = 0; i < n; i++) {
        uint8_t d = (uint8_t)(v >> 28);
        p[2 * i] = (uint8_t)(d < 10 ? '0' + d : 'A' + d - 10);
        p[2 * i + 1] = 0;
        v <<= 4;
    }
}

/* serial number from the chip's unique ID -> macOS names the port /dev/cu.usbmodem<serial> */
static uint8_t *serial_desc(USBD_SpeedTypeDef s, uint16_t *len)
{
    (void)s;
    uint32_t d0 = *(uint32_t *)(UID_BASE) + *(uint32_t *)(UID_BASE + 8);
    uint32_t d1 = *(uint32_t *)(UID_BASE + 4);
    int_to_unicode(d0, &s_serial[2], 8);
    int_to_unicode(d1, &s_serial[18], 4);
    *len = USB_SIZ_STRING_SERIAL;
    return s_serial;
}

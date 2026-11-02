/* nvstore.c - settings, calibration and tag database image. See nvstore.h. */
#include <string.h>
#include <stddef.h>
#include "nvstore.h"
#include "reader.h"
#include "calibration.h"
#include "tagdb.h"
#include "crc16.h"
#include "platform.h"

#define NV_MAGIC   0x564E5243u      /* "CRNV" */
#define NV_VERSION 1u

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint16_t crc;
    uint16_t reserved;
    reader_profile_t profile;
    uint32_t lo_khz;
    uint8_t  tx_level, pa_en, ref_atten, pad;
    cal_t    cal;
    tagdb_t  db;
} nv_image_t;

static nv_image_t s_img;            /* too big for the stack */

/* the CRC covers everything after the header */
static uint16_t image_crc(const nv_image_t *m)
{
    return crc16_ccitt((const uint8_t *)&m->profile, sizeof *m - offsetof(nv_image_t, profile));
}

int nvstore_load(void)
{
    if (plat_nv_read(&s_img, sizeof s_img) != 0) return -1;
    if (s_img.magic != NV_MAGIC || s_img.version != NV_VERSION || s_img.size != sizeof s_img) return -1;
    if (s_img.crc != image_crc(&s_img)) return -1;

    g_rs.profile = s_img.profile;
    g_rs.lo_khz = s_img.lo_khz;
    g_rs.tx_level = s_img.tx_level;
    g_rs.pa_en = s_img.pa_en;
    g_rs.ref_atten = s_img.ref_atten;
    g_cal = s_img.cal;
    g_tagdb = s_img.db;
    return 0;
}

int nvstore_save(void)
{
    memset(&s_img, 0, sizeof s_img);
    s_img.magic = NV_MAGIC;
    s_img.version = NV_VERSION;
    s_img.size = (uint16_t)sizeof s_img;
    s_img.profile = g_rs.profile;
    s_img.lo_khz = g_rs.lo_khz;
    s_img.tx_level = g_rs.tx_level;
    s_img.pa_en = g_rs.pa_en;
    s_img.ref_atten = g_rs.ref_atten;
    s_img.cal = g_cal;
    s_img.db = g_tagdb;
    s_img.crc = image_crc(&s_img);
    return plat_nv_write(&s_img, sizeof s_img);
}

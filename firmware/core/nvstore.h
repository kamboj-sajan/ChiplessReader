/*
 * nvstore.h - keeps the settings, calibration and tag database across power cycles.
 * On the STM32 the image lives in its own flash sector; in the virtual reader, in a file.
 */
#ifndef NVSTORE_H
#define NVSTORE_H

#include <stdint.h>

/* Loads the stored image into g_rs, g_cal and g_tagdb. Returns 0, or -1 if nothing valid is stored. */
int nvstore_load(void);
/* Stores the current g_rs configuration, g_cal and g_tagdb. Returns 0, or -1 on a flash error. */
int nvstore_save(void);

#endif

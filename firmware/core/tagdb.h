/*
 * tagdb.h - the tag database held by the STM32.
 *
 * The reader decodes a bit pattern from the sweep, then looks it up here to identify the tag.
 * The Mac app edits the list (DB_PUT / DB_DELETE / DB_CLEAR); NV_SAVE stores it in flash.
 */
#ifndef TAGDB_H
#define TAGDB_H

#include <stdint.h>
#include "app_config.h"

typedef struct {
    uint32_t id;                    /* bit k = resonator k (lowest frequency = bit 0) */
    uint8_t  n_bits;                /* tag format this ID belongs to                  */
    char     name[TAGDB_NAME_LEN];  /* NUL-padded                                     */
} tagdb_entry_t;

typedef struct {
    uint16_t      count;
    tagdb_entry_t entry[TAGDB_CAPACITY];
} tagdb_t;

extern tagdb_t g_tagdb;

void tagdb_clear(void);
/* add, or rename if (id, n_bits) already exists. Returns the index, or -1 if the list is full */
int  tagdb_put(uint32_t id, uint8_t n_bits, const char *name, int name_len);
/* returns 0, or -1 if (id, n_bits) is not in the list */
int  tagdb_delete(uint32_t id, uint8_t n_bits);
/* closest entry with the same n_bits within max_errors differing bits; exact match wins.
 * Returns the index or -1; *errors = number of differing bits. */
int  tagdb_match(uint32_t id, uint8_t n_bits, uint8_t max_errors, uint8_t *errors);

#endif

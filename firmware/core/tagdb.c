/* tagdb.c - tag database lookups. See tagdb.h. */
#include <string.h>
#include "tagdb.h"

tagdb_t g_tagdb;

static int popcount32(uint32_t v)
{
    int n = 0;
    while (v) { v &= v - 1; n++; }
    return n;
}

static int find(uint32_t id, uint8_t n_bits)
{
    for (int i = 0; i < g_tagdb.count; i++)
        if (g_tagdb.entry[i].id == id && g_tagdb.entry[i].n_bits == n_bits) return i;
    return -1;
}

void tagdb_clear(void)
{
    memset(&g_tagdb, 0, sizeof g_tagdb);
}

int tagdb_put(uint32_t id, uint8_t n_bits, const char *name, int name_len)
{
    int i = find(id, n_bits);
    if (i < 0) {
        if (g_tagdb.count >= TAGDB_CAPACITY) return -1;
        i = g_tagdb.count++;
    }
    tagdb_entry_t *e = &g_tagdb.entry[i];
    e->id = id;
    e->n_bits = n_bits;
    memset(e->name, 0, sizeof e->name);
    if (name_len > TAGDB_NAME_LEN) name_len = TAGDB_NAME_LEN;
    if (name_len > 0) memcpy(e->name, name, (size_t)name_len);
    return i;
}

int tagdb_delete(uint32_t id, uint8_t n_bits)
{
    int i = find(id, n_bits);
    if (i < 0) return -1;
    for (int j = i + 1; j < g_tagdb.count; j++) g_tagdb.entry[j - 1] = g_tagdb.entry[j];
    g_tagdb.count--;
    memset(&g_tagdb.entry[g_tagdb.count], 0, sizeof g_tagdb.entry[0]);
    return 0;
}

int tagdb_match(uint32_t id, uint8_t n_bits, uint8_t max_errors, uint8_t *errors)
{
    int best = -1, best_d = 1000;
    for (int i = 0; i < g_tagdb.count; i++) {
        if (g_tagdb.entry[i].n_bits != n_bits) continue;
        int d = popcount32(g_tagdb.entry[i].id ^ id);
        if (d <= max_errors && d < best_d) { best = i; best_d = d; }
    }
    if (best >= 0 && errors) *errors = (uint8_t)best_d;
    return best;
}

/* Single-producer / single-consumer byte FIFO.
 * Producer: USB CDC receive interrupt (or the host pty reader).
 * Consumer: app_poll() in the main loop. No locks needed for 1 producer + 1 consumer. */
#ifndef RING_BUFFER_H
#define RING_BUFFER_H

#include <stdint.h>

#define RB_SIZE 4096u   /* power of two */

typedef struct {
    volatile uint32_t head;   /* written by producer */
    volatile uint32_t tail;   /* written by consumer */
    uint8_t buf[RB_SIZE];
    volatile uint32_t dropped;
} ring_buffer_t;

static inline void rb_init(ring_buffer_t *rb) { rb->head = rb->tail = rb->dropped = 0; }

static inline void rb_push(ring_buffer_t *rb, const uint8_t *d, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) {
        uint32_t next = (rb->head + 1u) & (RB_SIZE - 1u);
        if (next == rb->tail) { rb->dropped++; return; }
        rb->buf[rb->head] = d[i];
        rb->head = next;
    }
}

static inline int rb_pop(ring_buffer_t *rb, uint8_t *b)
{
    if (rb->tail == rb->head) return 0;
    *b = rb->buf[rb->tail];
    rb->tail = (rb->tail + 1u) & (RB_SIZE - 1u);
    return 1;
}

#endif

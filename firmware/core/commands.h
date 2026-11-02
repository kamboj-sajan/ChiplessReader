#ifndef COMMANDS_H
#define COMMANDS_H
#include <stdint.h>
#include "protocol.h"
#include "reader.h"

/* Runs the handler for in->cmd. Returns a status code; fills out/out_len with the reply payload. */
uint8_t commands_dispatch(const frame_t *in, uint8_t *out, uint16_t *out_len);
void    commands_log_report(const tag_report_t *r);

#endif

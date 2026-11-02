#ifndef APP_H
#define APP_H
#include <stdint.h>

void app_init(const char *link_name);
/* called from the USB CDC receive callback (interrupt) or the host pty reader */
void app_on_rx(const uint8_t *data, uint32_t len);
/* call continuously from the main loop */
void app_poll(void);

#endif

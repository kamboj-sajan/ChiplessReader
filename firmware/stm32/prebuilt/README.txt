Firmware 0.3 for the STM32F407G-DISC1, built from firmware/stm32 with GCC 14.2.

  chipless_reader.elf     simulated RF front-end. Flash this first: it needs no RF parts.
  hw/chipless_reader.elf  real RF front-end. Flash this once the ADF4351, PE4312, MAX2235 and
                          AD8302 are wired as listed in firmware/stm32/Inc/board.h.

The .bin and .hex files hold the same programs. Use the .elf from STM32CubeIDE.
chipless_reader.elf has been run on a real board. hw/chipless_reader.elf has not: it needs the RF parts.

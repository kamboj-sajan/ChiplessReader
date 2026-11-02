# STM32F4DISCOVERY firmware for the chipless RFID reader.
# Sources: ../core (the reader itself, shared with the virtual reader) and Src/ (this board).
#
#   make                 -> build/chipless_reader.elf / .bin / .hex  (simulated RF backend)
#   make BACKEND=HW      -> real front-end backend (ADF4351 / PE4312 / AD8302 wired up)
#   make flash           -> program with STM32_Programmer_CLI (STM32CubeProgrammer) over ST-LINK
#
# Needs the Arm GNU toolchain (arm-none-eabi-gcc). STM32CubeIDE ships one; on macOS it lives in
#   /Applications/STM32CubeIDE.app/Contents/Eclipse/plugins/com.st.stm32cube.ide.mcu.externaltools.gnu-tools-for-stm32.*/tools/bin
# or install it separately (brew install --cask gcc-arm-embedded).

BACKEND ?= SIM
TARGET  := chipless_reader
BUILD   := build
PREFIX  ?= arm-none-eabi-
CC      := $(PREFIX)gcc
OBJCOPY := $(PREFIX)objcopy
SIZE    := $(PREFIX)size

CORE_DIR := ../core
HAL_DIR  := Drivers/STM32F4xx_HAL_Driver
CMSIS    := Drivers/CMSIS
USB_DIR  := Middlewares/ST/STM32_USB_Device_Library

C_SOURCES := \
  Src/main.c Src/platform_stm32.c Src/stm32f4xx_it.c Src/usbd_conf.c Src/usbd_desc.c Src/usbd_cdc_if.c Src/syscalls.c \
  $(wildcard $(CORE_DIR)/*.c) \
  $(CMSIS)/Device/ST/STM32F4xx/Source/system_stm32f4xx.c \
  $(wildcard $(HAL_DIR)/Src/*.c) \
  $(USB_DIR)/Core/Src/usbd_core.c $(USB_DIR)/Core/Src/usbd_ctlreq.c $(USB_DIR)/Core/Src/usbd_ioreq.c \
  $(USB_DIR)/Class/CDC/Src/usbd_cdc.c

ASM_SOURCES := $(CMSIS)/Device/ST/STM32F4xx/Source/startup_stm32f407xx.s

MCU     := -mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=hard
DEFS    := -DSTM32F407xx -DUSE_HAL_DRIVER -DHSE_VALUE=8000000U -DRF_BACKEND_$(BACKEND)
INCS    := -IInc -I$(CORE_DIR) -I$(HAL_DIR)/Inc -I$(CMSIS)/Include -I$(CMSIS)/Device/ST/STM32F4xx/Include \
           -I$(USB_DIR)/Core/Inc -I$(USB_DIR)/Class/CDC/Inc
CFLAGS  := $(MCU) $(DEFS) $(INCS) -std=gnu11 -O2 -g3 -Wall -ffunction-sections -fdata-sections \
           -fno-common -fsingle-precision-constant -Wno-double-promotion
LDFLAGS := $(MCU) -TSTM32F407VGTx_FLASH.ld --specs=nano.specs --specs=nosys.specs -u _printf_float \
           -Wl,--gc-sections -Wl,-Map=$(BUILD)/$(TARGET).map -Wl,--print-memory-usage -lm

OBJS := $(addprefix $(BUILD)/obj/,$(notdir $(C_SOURCES:.c=.o))) \
        $(addprefix $(BUILD)/obj/,$(notdir $(ASM_SOURCES:.s=.o)))
vpath %.c $(sort $(dir $(C_SOURCES)))
vpath %.s $(sort $(dir $(ASM_SOURCES)))

all: $(BUILD)/$(TARGET).elf $(BUILD)/$(TARGET).bin $(BUILD)/$(TARGET).hex

$(BUILD)/obj/%.o: %.c Makefile | $(BUILD)/obj
	$(CC) -c $(CFLAGS) -MMD -MP $< -o $@

$(BUILD)/obj/%.o: %.s Makefile | $(BUILD)/obj
	$(CC) -c $(MCU) -x assembler-with-cpp $< -o $@

$(BUILD)/$(TARGET).elf: $(OBJS)
	$(CC) $(OBJS) $(LDFLAGS) -o $@
	$(SIZE) $@

$(BUILD)/$(TARGET).bin: $(BUILD)/$(TARGET).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/$(TARGET).hex: $(BUILD)/$(TARGET).elf
	$(OBJCOPY) -O ihex $< $@

$(BUILD)/obj:
	mkdir -p $@

flash: $(BUILD)/$(TARGET).elf
	STM32_Programmer_CLI -c port=SWD -w $< -v -rst

clean:
	rm -rf $(BUILD)

-include $(wildcard $(BUILD)/obj/*.d)
.PHONY: all flash clean

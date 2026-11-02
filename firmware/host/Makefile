# Virtual reader: the firmware core compiled for macOS / Linux with the simulated RF backend.
#   make            -> build/chipless-vreader
#   make run        -> build and start it
CC      ?= cc
CFLAGS  ?= -O2 -g
CFLAGS  += -std=c11 -Wall -Wextra -Wno-unused-parameter -DRF_BACKEND_SIM -I../core
LDLIBS  += -lm

CORE    := $(wildcard ../core/*.c)
SRCS    := main_host.c $(CORE)
OUT     := build/chipless-vreader

all: $(OUT)

$(OUT): $(SRCS) $(wildcard ../core/*.h)
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $(SRCS) $(LDLIBS)

run: $(OUT)
	./$(OUT)

clean:
	rm -rf build

.PHONY: all run clean test

# unit tests for the core (CRC, frame parser, ADF4351 register maths)
test: build/test_core
	./build/test_core

build/test_core: ../tests/test_core.c ../core/crc16.c ../core/protocol.c ../core/adf4351.c ../core/calibration.c ../core/tagdb.c
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

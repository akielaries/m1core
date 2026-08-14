APP  := hello
SRCS := main.c

include ../../bsp/bsp.mk

# a fast-baud variant for the testbenches. BAUDDIV is clocks per bit, so a real
# 115200 frame takes thousands of cycles and is hopeless to simulate
ifndef VARIANT
all: variant

.PHONY: variant
variant:
	@$(MAKE) --no-print-directory VARIANT=1 APP=hello_sim BUILD=build-sim \
	    EXTRA_CFLAGS=-DSIM_FAST_BAUD
endif

APP  := blink
SRCS := main.c

include ../../bsp/bsp.mk

# a short delay variant for the testbenches. the real one takes millions of
# cycles per toggle, which is fine on hardware and hopeless to simulate
ifndef VARIANT
all: variant

.PHONY: variant
variant:
	@$(MAKE) --no-print-directory VARIANT=1 APP=blink_sim BUILD=build-sim \
	    EXTRA_CFLAGS=-DDELAY_ITERS=64u
endif

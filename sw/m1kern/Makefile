# builds m1kern's examples for m1core
#
# m1kern lives in its own repository, so this is a thin wrapper rather than a
# copy. override M1KERN_DIR if yours is somewhere else

M1KERN_DIR ?= ../../../m1kern
BUILD      := build

# must match the clock the fabric was synthesised with. the tang primer 25k
# divides its 50 MHz oscillator by two in boards/gw5a25/top.v
SYSTEM_CLOCK_HZ ?= 25000000

TARGET ?= 01_blink.elf

.PHONY: all clean

all:
	@test -d $(M1KERN_DIR) || { echo "m1kern not found at $(M1KERN_DIR)"; exit 1; }
	cmake -S $(M1KERN_DIR) -B $(BUILD) \
	    -DM1KERN_TARGET=m1core \
	    -DSYSTEM_CLOCK_HZ=$(SYSTEM_CLOCK_HZ)
	cmake --build $(BUILD) --target $(TARGET) $(ARGS)
	@echo
	@echo "load $(BUILD)/bin/$(basename $(TARGET)).elf from gdb, then run"

clean:
	rm -rf $(BUILD)

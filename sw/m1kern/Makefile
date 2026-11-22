# builds m1kern's examples for m1core
#
# m1kern is a git submodule at ./m1kern, the example sources are in
# m1kern/examples/<name>/. after cloning run
#   git submodule update --init
#
#   make                                   01_blink for the tang primer 25k
#   make BOARD=basys3 TARGET=05_preemption

M1KERN_DIR ?= m1kern
BOARD      ?= gw5a25
TARGET     ?= 01_blink
BUILD      := build/$(BOARD)

# must match the clock the fabric was synthesised with, there is no pll to read
# back. the 25k divides its 50 MHz oscillator by two, the basys 3 mmcm makes
# 50 MHz from 100 MHz
clock_gw5a25 := 25000000
clock_basys3 := 50000000
SYSTEM_CLOCK_HZ ?= $(clock_$(BOARD))

ifeq ($(SYSTEM_CLOCK_HZ),)
$(error unknown BOARD=$(BOARD), use gw5a25 or basys3 or set SYSTEM_CLOCK_HZ)
endif

.PHONY: all list clean

all:
	@test -f $(M1KERN_DIR)/CMakeLists.txt || { echo "m1kern missing, run: git submodule update --init"; exit 1; }
	cmake -S $(M1KERN_DIR) -B $(BUILD) \
	    -DM1KERN_TARGET=m1core \
	    -DSYSTEM_CLOCK_HZ=$(SYSTEM_CLOCK_HZ)
	cmake --build $(BUILD) --target $(TARGET).elf $(ARGS)
	@echo
	@echo "built $(BUILD)/bin/$(TARGET).elf at $(SYSTEM_CLOCK_HZ) Hz"
	@echo "load it from gdb: (gdb) file $(BUILD)/bin/$(TARGET).elf, then reload"

list:
	@ls $(M1KERN_DIR)/examples

clean:
	rm -rf build

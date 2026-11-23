# builds m1kern's examples for m1core
#
# m1kern is a git submodule at ./m1kern. our own applications are in
# apps/<name>/main.c, the kernel's stock examples in m1kern/examples/<name>/.
# both build the same way. after cloning run
#   git submodule update --init
#
#   make                                   m1core_demo for the tang primer 25k
#   make BOARD=basys3
#   make BOARD=basys3 TARGET=05_preemption

M1KERN_DIR ?= m1kern
BOARD      ?= gw5a25
TARGET     ?= m1core_demo
APPS       := $(wildcard $(CURDIR)/apps/*)
BUILD      := build/$(BOARD)

# must match the clock the fabric was synthesised with, there is no pll to read
# back. the 25k runs straight off its 50 MHz oscillator (boards/gw5a25/mcu.yaml),
# the basys 3 mmcm makes 50 MHz from 100 MHz
clock_gw5a25 := 50000000
clock_basys3 := 50000000
SYSTEM_CLOCK_HZ ?= $(clock_$(BOARD))

# board only peripherals, the ones on an expansion slot of that board's own
# mcu.yaml. apps test the define, and the cheby headers come from the board
# directory so firmware and rtl share one register description
cflags_gw5a25 :=
cflags_basys3 := -DM1CORE_BOARD_BASYS3 -I$(abspath ../../boards/xc7a35t_basys3/periph)
BOARD_CFLAGS  := $(cflags_$(BOARD))

ifeq ($(SYSTEM_CLOCK_HZ),)
$(error unknown BOARD=$(BOARD), use gw5a25 or basys3 or set SYSTEM_CLOCK_HZ)
endif

.PHONY: all list clean

all:
	@test -f $(M1KERN_DIR)/CMakeLists.txt || { echo "m1kern missing, run: git submodule update --init"; exit 1; }
	cmake -S $(M1KERN_DIR) -B $(BUILD) \
	    -DM1KERN_TARGET=m1core \
	    -DSYSTEM_CLOCK_HZ=$(SYSTEM_CLOCK_HZ) \
	    -DCMAKE_C_FLAGS="$(BOARD_CFLAGS)" \
	    -DM1KERN_EXTRA_EXAMPLES="$(subst $(eval) ,;,$(APPS))"
	cmake --build $(BUILD) --target $(TARGET).elf $(ARGS)
	@echo
	@echo "built $(BUILD)/bin/$(TARGET).elf at $(SYSTEM_CLOCK_HZ) Hz"
	@echo "load it from gdb: (gdb) file $(BUILD)/bin/$(TARGET).elf, then reload"

list:
	@echo "apps/ (this repo):"; ls apps | sed 's/^/  /'
	@echo "m1kern/examples/:"; ls $(M1KERN_DIR)/examples | sed 's/^/  /'

clean:
	rm -rf build

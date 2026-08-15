# shared build rules for m1 soc applications
#
# an application Makefile only has to say what it is called and what it is made
# of:
#
#   APP  := blink
#   SRCS := main.c
#   include ../../bsp/bsp.mk
#
# m1core.h is the device header: the register map and peripheral structs, the
# same role stm32f4xx.h or GOWIN_M1.h plays for a vendor part
#
# everything below is the board support: the startup code, the linker script,
# the register map header, and the arm toolchain flags

BSP_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
ROOT    := $(BSP_DIR)../../..

CROSS   ?= arm-none-eabi-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
SIZE    := $(CROSS)size

BUILD   ?= build

# cortex-m1 is armv6-m, thumb only
ARCH    := -mcpu=cortex-m1 -mthumb
CFLAGS  := $(ARCH) -Og -g3 -Wall -Wextra -ffreestanding \
           -ffunction-sections -fdata-sections -I$(BSP_DIR) $(EXTRA_CFLAGS)
LDFLAGS := $(ARCH) -T $(BSP_DIR)link.ld -nostdlib -Wl,--gc-sections \
           -Wl,-Map=$(BUILD)/$(APP).map

# armv6-m has no divide instruction, so anything dividing (or doing 64 bit
# maths) needs the libgcc helpers. -nostdlib drops them, so ask for libgcc back
# explicitly rather than discovering the missing __aeabi_uidiv later
LDLIBS := -lgcc

# an app can set BSP_SRCS empty to opt out of the startup code, as the isa test
# does since it carries its own vector table
BSP_SRCS ?= $(BSP_DIR)startup.c $(BSP_DIR)uart.c

OBJS := $(addprefix $(BUILD)/,$(notdir $(SRCS:.c=.o) $(SRCS:.S=.o))) \
        $(addprefix $(BUILD)/,$(notdir $(BSP_SRCS:.c=.o)))
OBJS := $(sort $(filter %.o,$(OBJS)))

VPATH := . $(BSP_DIR)

.PHONY: all clean
all: $(BUILD)/$(APP).hex
	@$(SIZE) $(BUILD)/$(APP).elf

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.S | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/$(APP).elf: $(OBJS) $(BSP_DIR)link.ld | $(BUILD)
	$(CC) $(OBJS) $(LDFLAGS) -o $@ $(LDLIBS)

$(BUILD)/$(APP).bin: $(BUILD)/$(APP).elf
	$(OBJCOPY) -O binary $< $@

# 32 bit words, one per line, which is what $readmemh wants for a word
# addressed memory. objcopy -O verilog does not produce that
$(BUILD)/$(APP).hex: $(BUILD)/$(APP).bin
	python3 $(ROOT)/tools/bin2hex.py $< $@

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf build build-sim

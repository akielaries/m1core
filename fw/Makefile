CROSS   ?= arm-none-eabi-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
SIZE    := $(CROSS)size

TARGET := blink
BUILD  := build

# cortex-m1 is armv6-m, thumb only
ARCH    := -mcpu=cortex-m1 -mthumb
CFLAGS  := $(ARCH) -Og -g3 -Wall -Wextra -ffreestanding \
           -ffunction-sections -fdata-sections
LDFLAGS := $(ARCH) -T link.ld -nostdlib -Wl,--gc-sections -Wl,-Map=$(BUILD)/$(TARGET).map

SRCS := startup.c blink.c
OBJS := $(addprefix $(BUILD)/,$(SRCS:.c=.o))

.PHONY: all clean

all: $(BUILD)/$(TARGET).hex $(BUILD)/isatest.hex $(BUILD)/blink_sim.hex
	$(SIZE) $(BUILD)/$(TARGET).elf $(BUILD)/isatest.elf

$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.S | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/$(TARGET).elf: $(OBJS) link.ld | $(BUILD)
	$(CC) $(OBJS) $(LDFLAGS) -o $@

# same blink, but with a delay short enough to simulate. the real one takes
# millions of cycles per toggle, which is fine on hardware and hopeless in a
# testbench
$(BUILD)/blink_sim.o: blink.c | $(BUILD)
	$(CC) $(CFLAGS) -DDELAY_ITERS=64u -c $< -o $@

$(BUILD)/blink_sim.elf: $(BUILD)/startup.o $(BUILD)/blink_sim.o link.ld | $(BUILD)
	$(CC) $(BUILD)/startup.o $(BUILD)/blink_sim.o $(LDFLAGS) -o $@

# the isa test is standalone assembly with its own vector table
$(BUILD)/isatest.elf: $(BUILD)/isatest.o link.ld | $(BUILD)
	$(CC) $(BUILD)/isatest.o $(LDFLAGS) -o $@

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@

# 32 bit words, one per line, for $readmemh in the testbench
$(BUILD)/%.hex: $(BUILD)/%.bin
	python3 ../tools/bin2hex.py $< $@

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)

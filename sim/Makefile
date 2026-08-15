IVERILOG ?= iverilog
VVP      ?= vvp
ROOT     := ..
BUILD    := build

DAP_RTL := $(ROOT)/rtl/debug/swd_phy.v $(ROOT)/rtl/debug/sw_dp.v
MVP_RTL := $(DAP_RTL) \
           $(ROOT)/rtl/debug/mem_ap.v \
           $(ROOT)/rtl/debug/ppb_regs.v \
           $(ROOT)/rtl/soc/ahb_fabric.v \
           $(ROOT)/rtl/soc/ahb_sram.v \
           $(ROOT)/rtl/periph/ahb_gpio.v \
           $(ROOT)/rtl/periph/apb_uart.v \
           $(ROOT)/rtl/soc/ahb_apb_bridge.v \
           $(ROOT)/rtl/soc/m1core_apb.v \
           $(ROOT)/rtl/soc/ahb_arb.v \
           $(ROOT)/rtl/core/m1core_cpu.v \
           $(ROOT)/rtl/core/m1core_nvic.v \
           $(ROOT)/rtl/soc/m1core_soc.v

IFLAGS := -g2012 -Wall -I$(ROOT)/tb

.PHONY: all checkproj checkgen dap core exc blink uart hello mvp fw m1kern wave clean

all: checkproj checkgen dap core exc blink uart hello mvp

# the gowin project keeps its own file list, so it can drift from the rtl on
# disk without simulation noticing. this is the cheap way to catch that
checkproj:
	@python3 $(ROOT)/tools/check_project.py

# the device header is generated from the soc description. this catches a hand
# edit to the header, or a change to the soc.yaml that was never regenerated
checkgen:
	@python3 $(ROOT)/tools/m1core_gen.py $(ROOT)/boards/gw5a25/soc.yaml \
	    --header $(ROOT)/sw/baremetal/bsp/m1core.h \
	    --memmap $(ROOT)/docs/memory-map.md \
	    --apb-rtl $(ROOT)/rtl/soc/m1core_apb.v --check

dap: $(BUILD)/tb_dap
	$(VVP) $<

core: $(BUILD)/tb_core fw
	$(VVP) $<

exc: $(BUILD)/tb_exc fw
	$(VVP) $<

blink: $(BUILD)/tb_blink fw
	$(VVP) $<

uart: $(BUILD)/tb_uart
	$(VVP) $<

hello: $(BUILD)/tb_hello fw
	$(VVP) $<

mvp: $(BUILD)/tb_mvp fw
	$(VVP) $<

# m1kern lives in its own repo, so this is opt-in rather than part of `all`.
# built with a low core clock so systick and the uart divider are small enough
# to simulate
M1KERN_DIR ?= $(ROOT)/../m1kern
M1KERN_BUILD := $(BUILD)/m1kern-cmake

m1kern: $(BUILD)/tb_m1kern
	@test -d $(M1KERN_DIR) || { echo "m1kern not found at $(M1KERN_DIR)"; exit 1; }
	cmake -S $(M1KERN_DIR) -B $(M1KERN_BUILD) \
	    -DM1KERN_TARGET=m1core -DSYSTEM_CLOCK_HZ=4000000 >/dev/null
	cmake --build $(M1KERN_BUILD) --target 01_blink.elf >/dev/null
	python3 $(ROOT)/tools/bin2hex.py $(M1KERN_BUILD)/bin/01_blink.bin $(BUILD)/m1kern.hex
	$(VVP) $<

$(BUILD)/tb_m1kern: $(MVP_RTL) $(ROOT)/tb/tb_m1kern.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_m1kern.sv

# the testbenches load real firmware images, so build them first
fw:
	@$(MAKE) --no-print-directory -C $(ROOT)/sw/baremetal

wave: $(BUILD)/tb_mvp
	$(VVP) $< +vcd
	gtkwave tb_mvp.vcd

$(BUILD)/tb_dap: $(DAP_RTL) $(ROOT)/tb/tb_dap.sv $(ROOT)/tb/swd_host.svh | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(DAP_RTL) $(ROOT)/tb/tb_dap.sv

$(BUILD)/tb_mvp: $(MVP_RTL) $(ROOT)/tb/tb_mvp.sv $(ROOT)/tb/swd_host.svh | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_mvp.sv

$(BUILD)/tb_core: $(MVP_RTL) $(ROOT)/tb/tb_core.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_core.sv

$(BUILD)/tb_exc: $(MVP_RTL) $(ROOT)/tb/tb_exc.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_exc.sv

$(BUILD)/tb_blink: $(MVP_RTL) $(ROOT)/tb/tb_blink.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_blink.sv

$(BUILD)/tb_hello: $(MVP_RTL) $(ROOT)/tb/tb_hello.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_hello.sv

$(BUILD)/tb_uart: $(ROOT)/rtl/soc/ahb_apb_bridge.v $(ROOT)/rtl/periph/apb_uart.v $(ROOT)/tb/tb_uart.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $^

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) *.vcd

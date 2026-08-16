IVERILOG ?= iverilog
VVP      ?= vvp
ROOT     := ..
BUILD    := build
# m1kern's device header is generated from the same description, so the two
# bsps cannot disagree about an address
M1KERN   := $(ROOT)/../m1kern

DAP_RTL := $(ROOT)/rtl/debug/swd_phy.v $(ROOT)/rtl/debug/sw_dp.v
MVP_RTL := $(DAP_RTL) \
           $(ROOT)/rtl/debug/mem_ap.v \
           $(ROOT)/rtl/debug/ppb_regs.v \
           $(ROOT)/rtl/mcu/ahb_fabric.v \
           $(ROOT)/rtl/mcu/ahb_sram.v \
           $(ROOT)/rtl/periph/ahb_gpio.v \
           $(ROOT)/rtl/periph/apb_uart.v \
           $(ROOT)/rtl/periph/apb_timer.v \
           $(ROOT)/rtl/periph/apb_spi.v \
           $(ROOT)/rtl/periph/apb_i2c.v \
           $(ROOT)/rtl/periph/apb_rtc.v \
           $(ROOT)/rtl/mcu/ahb_apb_bridge.v \
           $(ROOT)/rtl/mcu/m1core_apb.v \
           $(ROOT)/rtl/mcu/ahb_arb.v \
           $(ROOT)/rtl/core/m1core_cpu.v \
           $(ROOT)/rtl/core/m1core_nvic.v \
           $(ROOT)/rtl/mcu/m1core_mcu.v

IFLAGS := -g2012 -Wall -I$(ROOT)/tb

.PHONY: all checkproj checkgen checkyaml dap core exc blink uart hello mvp exp periph fw m1kern wave clean

all: checkproj checkgen checkyaml dap core exc blink uart hello mvp exp periph

# the gowin project keeps its own file list, so it can drift from the rtl on
# disk without simulation noticing. this is the cheap way to catch that
checkproj:
	@python3 $(ROOT)/tools/check_project.py

# the device header is generated from the mcu description. this catches a hand
# edit to the header, or a change to the mcu.yaml that was never regenerated
# the configurator writes mcu.yaml back in place to keep its comments. this is
# the check that the in place editing is faithful: read the file, write it back
# with nothing changed, and require the bytes to be identical
checkyaml:
	@python3 $(ROOT)/tools/mcu_yaml.py $(ROOT)/boards/gw5a25/mcu.yaml

checkgen:
	@python3 $(ROOT)/tools/m1core_gen.py $(ROOT)/boards/gw5a25/mcu.yaml \
	    --header $(ROOT)/sw/baremetal/bsp/m1core.h \
	    --memmap $(ROOT)/docs/memory-map.md \
	    --apb-rtl $(ROOT)/rtl/mcu/m1core_apb.v \
	    --ahb-rtl $(ROOT)/rtl/mcu/ahb_fabric.v \
	    --mcu-rtl $(ROOT)/rtl/mcu/m1core_mcu.v \
	    --cmsis-header $(M1KERN)/targets/m1core/bsp/system/M1CORE.h --check

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

periph: $(BUILD)/tb_periph
	$(VVP) $<

exp: $(BUILD)/tb_exp
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

# the expansion test runs against rtl generated from tb/exp_mcu.yaml rather
# than from the board file, so it tests the generator and not just the one
# configuration that happens to be checked in. m1core_mcu.v is spliced, not
# written whole, so the board copy is the starting point
GEN := $(BUILD)/gen
# every generated file has to come from the same description. taking the apb
# wrapper from the board build while the mcu top came from here is what made
# the peripheral ports not line up
EXP_RTL := $(filter-out $(ROOT)/rtl/mcu/ahb_fabric.v $(ROOT)/rtl/mcu/m1core_mcu.v $(ROOT)/rtl/mcu/m1core_apb.v,$(MVP_RTL)) \
           $(GEN)/ahb_fabric.v $(GEN)/m1core_mcu.v $(GEN)/m1core_apb.v

$(GEN)/m1core_mcu.v $(GEN)/ahb_fabric.v $(GEN)/m1core_apb.v: $(ROOT)/tb/exp_mcu.yaml $(ROOT)/rtl/mcu/m1core_mcu.v $(ROOT)/tools/m1core_gen.py
	@mkdir -p $(GEN)
	@cp $(ROOT)/rtl/mcu/m1core_mcu.v $(GEN)/m1core_mcu.v
	@python3 $(ROOT)/tools/m1core_gen.py $(ROOT)/tb/exp_mcu.yaml \
	    --mcu-rtl $(GEN)/m1core_mcu.v --ahb-rtl $(GEN)/ahb_fabric.v \
	    --apb-rtl $(GEN)/m1core_apb.v

$(BUILD)/tb_exp: $(EXP_RTL) $(ROOT)/tb/tb_exp.sv $(ROOT)/tb/swd_host.svh | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(EXP_RTL) $(ROOT)/tb/tb_exp.sv

PERIPH_RTL := $(ROOT)/rtl/periph/apb_spi.v $(ROOT)/rtl/periph/apb_i2c.v \
              $(ROOT)/rtl/periph/apb_rtc.v

$(BUILD)/tb_periph: $(PERIPH_RTL) $(ROOT)/tb/tb_periph.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(PERIPH_RTL) $(ROOT)/tb/tb_periph.sv

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

$(BUILD)/tb_uart: $(ROOT)/rtl/mcu/ahb_apb_bridge.v $(ROOT)/rtl/periph/apb_uart.v $(ROOT)/tb/tb_uart.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $^

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) *.vcd

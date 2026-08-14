IVERILOG ?= iverilog
VVP      ?= vvp
ROOT     := ..
BUILD    := build

DAP_RTL := $(ROOT)/rtl/dap/swd_phy.v $(ROOT)/rtl/dap/sw_dp.v
MVP_RTL := $(DAP_RTL) \
           $(ROOT)/rtl/dap/mem_ap.v \
           $(ROOT)/rtl/debug/ppb_regs.v \
           $(ROOT)/rtl/soc/ahb_fabric.v \
           $(ROOT)/rtl/soc/ahb_sram.v \
           $(ROOT)/rtl/soc/ahb_gpio.v \
           $(ROOT)/rtl/soc/ahb_arb.v \
           $(ROOT)/rtl/core/armv6m_core.v \
           $(ROOT)/rtl/m1_mvp_top.v

IFLAGS := -g2012 -Wall -I$(ROOT)/tb

.PHONY: all dap core blink mvp fw wave clean

all: dap core blink mvp

dap: $(BUILD)/tb_dap
	$(VVP) $<

core: $(BUILD)/tb_core fw
	$(VVP) $<

blink: $(BUILD)/tb_blink fw
	$(VVP) $<

mvp: $(BUILD)/tb_mvp fw
	$(VVP) $<

# the mvp test loads the real firmware image over swd, so build it first
fw:
	$(MAKE) -C $(ROOT)/fw

wave: $(BUILD)/tb_mvp
	$(VVP) $< +vcd
	gtkwave tb_mvp.vcd

$(BUILD)/tb_dap: $(DAP_RTL) $(ROOT)/tb/tb_dap.sv $(ROOT)/tb/swd_host.svh | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(DAP_RTL) $(ROOT)/tb/tb_dap.sv

$(BUILD)/tb_mvp: $(MVP_RTL) $(ROOT)/tb/tb_mvp.sv $(ROOT)/tb/swd_host.svh | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_mvp.sv

$(BUILD)/tb_core: $(MVP_RTL) $(ROOT)/tb/tb_core.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_core.sv

$(BUILD)/tb_blink: $(MVP_RTL) $(ROOT)/tb/tb_blink.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_blink.sv

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) *.vcd

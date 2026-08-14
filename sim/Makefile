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
           $(ROOT)/rtl/soc/ahb_arb.v \
           $(ROOT)/rtl/core/m1core_cpu.v \
           $(ROOT)/rtl/soc/m1core_soc.v

IFLAGS := -g2012 -Wall -I$(ROOT)/tb

.PHONY: all dap core blink uart hello mvp fw wave clean

all: dap core blink uart hello mvp

dap: $(BUILD)/tb_dap
	$(VVP) $<

core: $(BUILD)/tb_core fw
	$(VVP) $<

blink: $(BUILD)/tb_blink fw
	$(VVP) $<

uart: $(BUILD)/tb_uart
	$(VVP) $<

hello: $(BUILD)/tb_hello fw
	$(VVP) $<

mvp: $(BUILD)/tb_mvp fw
	$(VVP) $<

# the testbenches load real firmware images, so build them first
fw:
	@$(MAKE) --no-print-directory -C $(ROOT)/sw

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

$(BUILD)/tb_hello: $(MVP_RTL) $(ROOT)/tb/tb_hello.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_hello.sv

$(BUILD)/tb_uart: $(ROOT)/rtl/soc/ahb_apb_bridge.v $(ROOT)/rtl/periph/apb_uart.v $(ROOT)/tb/tb_uart.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $^

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) *.vcd

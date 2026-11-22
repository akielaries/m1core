IVERILOG ?= iverilog
VVP      ?= vvp
ROOT     := ..
BUILD    := build
# m1kern's device header is generated from the same description, so the two
# bsps cannot disagree about an address
# m1kern is a submodule at sw/m1kern/m1kern. a clone without
# `git submodule update --init` does not have it, so the generated device
# header is checked when it is present and skipped when it is not, rather than
# making the whole regression depend on the submodule
M1KERN     := $(ROOT)/sw/m1kern/m1kern
M1KERN_HDR := $(wildcard $(M1KERN)/targets/m1core/bsp/system/M1CORE.h)
ifneq ($(M1KERN_HDR),)
CMSIS_ARG  := --cmsis-header $(M1KERN_HDR)
endif

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
           $(ROOT)/rtl/core/m1core_decode.v \
           $(ROOT)/rtl/core/m1core_nvic.v \
           $(ROOT)/rtl/mcu/m1core_mcu.v

# simulation pins the core explicitly so tools/select_core.py, which picks the
# core for the gowin build, cannot silently change what a test exercises
IFLAGS := -g2012 -Wall -I$(ROOT)/tb -DM1CORE_FORCE_MULTICYCLE
PFLAGS := -g2012 -Wall -I$(ROOT)/tb -DM1CORE_PIPELINE

.PHONY: all checkproj checkgen checkyaml dap core isarand exc FORCE blink uart hello mvp exp periph fw m1kern m1kernp wave clean \
        fetch pipe aluequiv corep isarandp blinkp hellop mvpp excp pipeline

all: checkproj checkgen checkyaml dap core isarand exc FORCE blink uart hello mvp exp periph pipeline

# everything that exercises the pipelined core. kept as its own group so it is
# obvious which results belong to which core
# excp is in: all 15 exception checks pass on the pipelined core. it was left
# out while 6 of them failed
# hellop is in: it used to miss the testbench's 50 ms window because a multi
# register transfer drained the pipeline before it could start, and it does not
# any more
pipeline: fetch pipe aluequiv corep isarandp blinkp mvpp hellop excp

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

# the testbenches' clock define. gitignored and generated here, like
# isarand_blocks.vh, so a fresh clone (ci) builds it before tb_core and
# tb_isarand include it
CLOCK_VH := $(ROOT)/tb/m1core_clock.vh

$(CLOCK_VH): $(ROOT)/boards/gw5a25/mcu.yaml $(ROOT)/tools/m1core_gen.py
	@python3 $(ROOT)/tools/m1core_gen.py $(ROOT)/boards/gw5a25/mcu.yaml --sim-header $@

checkgen:
	@python3 $(ROOT)/tools/m1core_gen.py $(ROOT)/boards/gw5a25/mcu.yaml \
	    --header $(ROOT)/sw/baremetal/bsp/m1core.h \
	    --memmap $(ROOT)/docs/memory-map.md \
	    --apb-rtl $(ROOT)/rtl/mcu/m1core_apb.v \
	    --ahb-rtl $(ROOT)/rtl/mcu/ahb_fabric.v \
	    --mcu-rtl $(ROOT)/rtl/mcu/m1core_mcu.v \
	    $(CMSIS_ARG) --check

dap: $(BUILD)/tb_dap
	$(VVP) $<

core: $(BUILD)/tb_core fw
	$(VVP) $<

# the pipelined core under construction. rtl/pipe is deliberately outside the
# board project: gowin picks a top module by looking for one that nothing
# instantiates, and an unused module in the .gprj cost a build once already
fetch: $(BUILD)/tb_fetch
	$(VVP) $<

$(BUILD)/tb_fetch: $(ROOT)/tb/tb_fetch.sv $(ROOT)/rtl/pipe/m1core_fetch.v
	@mkdir -p $(BUILD)
	iverilog $(PFLAGS) -o $@ $^

# the shared datapath against an independent model of the same architecture.
# the funnel shifter encodes lsl as a reversed lsr and decides its output class
# in parallel with the barrel, neither of which is checkable by reading
aluequiv: $(BUILD)/tb_alu_equiv
	$(VVP) $<

$(BUILD)/tb_alu_equiv: $(ROOT)/tb/tb_alu_equiv.sv $(ROOT)/rtl/pipe/m1core_alu.v
	@mkdir -p $(BUILD)
	iverilog $(PFLAGS) -o $@ $^

pipe: $(BUILD)/tb_pipe
	$(VVP) $<

$(BUILD)/tb_pipe: $(ROOT)/tb/tb_pipe.sv $(wildcard $(ROOT)/rtl/pipe/*.v) \
                  $(ROOT)/rtl/core/m1core_decode.v
	@mkdir -p $(BUILD)
	iverilog $(PFLAGS) -o $@ $^

# the randomised test is generated, so the .S is a build product and the seed
# is what is checked in. change the seed to get a different program
ISARAND_SEED   ?= 1
ISARAND_BLOCKS ?= 40
ISARAND_LEN    ?= 12

# make does not track variable values, so changing ISARAND_SEED on the command
# line would otherwise leave the previously generated program in place and
# silently test the same thing again. the parameters go through a stamp file
# whose recipe always runs but only writes when they actually differ
$(BUILD)/isarand.params: FORCE | $(BUILD)
	@echo "$(ISARAND_SEED) $(ISARAND_BLOCKS) $(ISARAND_LEN)" > $@.new
	@cmp -s $@.new $@ 2>/dev/null || mv $@.new $@
	@rm -f $@.new

FORCE:

$(ROOT)/sw/baremetal/tests/isarand/isarand.S: $(ROOT)/tools/isagen.py $(BUILD)/isarand.params
	@python3 $(ROOT)/tools/isagen.py -o $@ \
	    --blocks $(ISARAND_BLOCKS) --len $(ISARAND_LEN) --seed $(ISARAND_SEED)

isarand: $(BUILD)/tb_isarand fw
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

# m1kern is a submodule, so this is opt-in rather than part of `all`. built
# with a low core clock so systick and the uart divider are small enough to
# simulate. m1kern is the multi-cycle core, m1kernp the pipelined one
#
# m1kernp is the test that found push/pop writing back to msp while thread mode
# was on psp. tb_exc never runs push/pop on psp, an rtos does it on the first
# nested call in a thread
M1KERN_DIR ?= $(M1KERN)
M1KERN_BUILD := $(BUILD)/m1kern-cmake

$(BUILD)/m1kern.hex: FORCE | $(BUILD)
	@test -f $(M1KERN_DIR)/CMakeLists.txt || { echo "m1kern missing, run: git submodule update --init"; exit 1; }
	cmake -S $(M1KERN_DIR) -B $(M1KERN_BUILD) \
	    -DM1KERN_TARGET=m1core -DSYSTEM_CLOCK_HZ=4000000 >/dev/null
	cmake --build $(M1KERN_BUILD) --target 01_blink.elf >/dev/null
	python3 $(ROOT)/tools/bin2hex.py $(M1KERN_BUILD)/bin/01_blink.bin $@

m1kern: $(BUILD)/tb_m1kern $(BUILD)/m1kern.hex
	$(VVP) $<

m1kernp: $(BUILD)/tb_m1kernp $(BUILD)/m1kern.hex
	$(VVP) $<

$(BUILD)/tb_m1kern: $(MVP_RTL) $(ROOT)/tb/tb_m1kern.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_m1kern.sv

$(BUILD)/tb_m1kernp: $(PIPE_RTL) $(ROOT)/tb/tb_m1kern.sv | $(BUILD)
	$(IVERILOG) $(PFLAGS) -o $@ $(PIPE_RTL) $(ROOT)/tb/tb_m1kern.sv

# the testbenches load real firmware images, so build them first
fw: $(ROOT)/sw/baremetal/tests/isarand/isarand.S
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

# the .S carries the generated block count in tb/isarand_blocks.vh, which the
# bench includes, so the generator has to have run before the bench compiles
$(BUILD)/tb_isarand: $(MVP_RTL) $(ROOT)/tb/tb_isarand.sv $(CLOCK_VH) \
                     $(ROOT)/sw/baremetal/tests/isarand/isarand.S | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_isarand.sv

# the randomised program against the pipelined core. this is the strongest
# check there is: the reference is an independent model, not the other core
# real firmware against the pipelined core, which is the closest thing to the
# hardware test short of a bitstream
blinkp: $(BUILD)/tb_blinkp fw
	$(VVP) $<

$(BUILD)/tb_blinkp: $(PIPE_RTL) $(ROOT)/tb/tb_blink.sv | $(BUILD)
	$(IVERILOG) $(PFLAGS) -o $@ $(PIPE_RTL) $(ROOT)/tb/tb_blink.sv

hellop: $(BUILD)/tb_hellop fw
	$(VVP) $<

$(BUILD)/tb_hellop: $(PIPE_RTL) $(ROOT)/tb/tb_hello.sv | $(BUILD)
	$(IVERILOG) $(PFLAGS) -o $@ $(PIPE_RTL) $(ROOT)/tb/tb_hello.sv

$(BUILD)/tb_hello_r: $(MVP_RTL) $(ROOT)/tb/tb_hello.sv | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_hello.sv $(RATE) -s tb_hello -s rate3

# the full debug path: swd, dap, halt, register access, resume
mvpp: $(BUILD)/tb_mvpp fw
	$(VVP) $<

$(BUILD)/tb_mvpp: $(PIPE_RTL) $(ROOT)/tb/tb_mvp.sv $(ROOT)/tb/swd_host.svh | $(BUILD)
	$(IVERILOG) $(PFLAGS) -o $@ $(PIPE_RTL) $(ROOT)/tb/tb_mvp.sv

# the exception suite against the pipelined core
excp: $(BUILD)/tb_excp fw
	$(VVP) $<

$(BUILD)/tb_excp: $(PIPE_RTL) $(ROOT)/tb/tb_exc.sv | $(BUILD)
	$(IVERILOG) $(PFLAGS) -o $@ $(PIPE_RTL) $(ROOT)/tb/tb_exc.sv

isarandp: $(BUILD)/tb_isarandp fw
	$(VVP) $<

$(BUILD)/tb_isarandp: $(PIPE_RTL) $(ROOT)/tb/tb_isarand.sv $(CLOCK_VH) \
                     $(ROOT)/sw/baremetal/tests/isarand/isarand.S | $(BUILD)
	$(IVERILOG) $(PFLAGS) -o $@ $(PIPE_RTL) $(ROOT)/tb/tb_isarand.sv

$(BUILD)/tb_core: $(MVP_RTL) $(ROOT)/tb/tb_core.sv $(CLOCK_VH) | $(BUILD)
	$(IVERILOG) $(IFLAGS) -o $@ $(MVP_RTL) $(ROOT)/tb/tb_core.sv

# the same 148 checks, run against the pipelined core. this is the acceptance
# test for the new core: the multi-cycle one is the golden reference and the
# suite does not know or care which is underneath
PIPE_RTL := $(MVP_RTL) $(wildcard $(ROOT)/rtl/pipe/*.v)

corep: $(BUILD)/tb_corep fw
	$(VVP) $<

$(BUILD)/tb_corep: $(PIPE_RTL) $(ROOT)/tb/tb_core.sv $(CLOCK_VH) | $(BUILD)
	$(IVERILOG) $(PFLAGS) -o $@ $(PIPE_RTL) $(ROOT)/tb/tb_core.sv

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

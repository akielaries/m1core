# m1core on the basys 3
#   make           build build/<core>/top.bit with vivado
#   make prog      load it over the onboard usb-jtag
#   make gui       open the routed design (read only checkpoint)
#   make open      open the vivado project in the gui (creates it if missing)
#   make project   recreate the vivado project from rtl.tcl
#   make clean     remove the batch build output, keep the gui project
#   make distclean remove everything under build/
#   make gen       regenerate gen/ from mcu.yaml after editing it
#   make regs      regenerate periph/*_regs.{v,h} from their cheby yaml
#
# CORE=pipeline (default) or CORE=multicycle picks the cpu, see rtl.tcl. each
# core builds into its own build/<core>/ with its own project, so switching is
# just a different CORE= and nothing needs cleaning

VIVADO ?= /tools/Xilinx/2025.2/Vivado/bin/vivado
LOADER ?= openFPGALoader
CORE   ?= pipeline
export CORE
OUT    := build/$(CORE)

RTL := $(wildcard ../../rtl/*/*.v gen/*.v periph/*.v) top.v basys3.xdc build.tcl rtl.tcl

.PHONY: all prog gui open project clean distclean gen regs

all: $(OUT)/top.bit

$(OUT)/top.bit: $(RTL)
	@mkdir -p $(OUT)
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log vivado.log -notrace \
	  -source $(CURDIR)/build.tcl -tclargs $(CURDIR)/$(OUT)

prog: $(OUT)/top.bit
	$(LOADER) -b basys3 $(OUT)/top.bit

gui: $(OUT)/top.bit
	cd $(OUT) && $(VIVADO) -nojournal -nolog $(CURDIR)/$(OUT)/post_route.dcp &

# the project references the rtl in place, so source edits show up in it. its
# file list and core define are fixed when it is created, so `make project`
# after changing rtl.tcl
XPR := $(OUT)/proj/m1core_basys3.xpr

$(XPR):
	@mkdir -p $(OUT)
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log project.log -notrace \
	  -source $(CURDIR)/project.tcl -tclargs $(CURDIR)/$(OUT)

project:
	rm -rf $(OUT)/proj
	$(MAKE) --no-print-directory $(XPR)

open: $(XPR)
	cd $(OUT)/proj && $(VIVADO) -nojournal -nolog $(CURDIR)/$(XPR) &

clean:
	cd build 2>/dev/null && find . -mindepth 2 -maxdepth 2 ! -name proj -exec rm -rf {} + || true

distclean:
	rm -rf build

# this board's soc, generated from its own mcu.yaml. checked in, like rtl/mcu,
# so the gui project opens without running anything first
gen:
	cp ../../rtl/mcu/m1core_mcu.v gen/m1core_mcu.v
	cd ../.. && python3 tools/m1core_gen.py boards/xc7a35t_basys3/mcu.yaml \
	  --mcu-rtl boards/xc7a35t_basys3/gen/m1core_mcu.v \
	  --ahb-rtl boards/xc7a35t_basys3/gen/ahb_fabric.v \
	  --apb-rtl boards/xc7a35t_basys3/gen/m1core_apb.v

# register files and c headers for the board peripherals. each
# periph/<name>_regs.yaml gives periph/<name>_regs.v and periph/<name>_regs.h
CHEBY ?= cheby
regs:
	cd periph && for y in *_regs.yaml; do \
	  n=$${y%.yaml}; echo "cheby $$y -> $$n.v $$n.h"; \
	  $(CHEBY) -i $$y --hdl verilog --gen-hdl $$n.v && \
	  $(CHEBY) -i $$y --gen-c $$n.h || exit 1; \
	done

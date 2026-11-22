# m1core on the basys 3
#   make           build build/<core>/top.bit with vivado
#   make prog      load it over the onboard usb-jtag
#   make gui       open the routed design (read only checkpoint)
#   make open      open the vivado project in the gui (creates it if missing)
#   make project   recreate the vivado project from rtl.tcl
#   make clean     remove the batch build output, keep the gui project
#   make distclean remove everything under build/
#
# CORE=multicycle (default) or CORE=pipeline picks the cpu, see rtl.tcl. each
# core builds into its own build/<core>/ with its own project, so switching is
# just a different CORE= and nothing needs cleaning

VIVADO ?= /tools/Xilinx/2025.2/Vivado/bin/vivado
LOADER ?= openFPGALoader
CORE   ?= multicycle
export CORE
OUT    := build/$(CORE)

RTL := $(wildcard ../../rtl/*/*.v) top.v basys3.xdc build.tcl rtl.tcl

.PHONY: all prog gui open project clean distclean

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

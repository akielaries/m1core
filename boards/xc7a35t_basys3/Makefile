# m1core on the basys 3
#   make         build build/top.bit with vivado
#   make prog    load it over the onboard usb-jtag
#   make gui     open the routed design
#   make open    open a vivado project in the gui (creates it if missing)
#   make clean
#
# CORE=multicycle (default) or CORE=pipeline picks the cpu, see rtl.tcl.
# switching cores needs a clean, the make rule does not track it

VIVADO ?= /tools/Xilinx/2025.2/Vivado/bin/vivado
LOADER ?= openFPGALoader
CORE   ?= multicycle
export CORE
OUT    := build

RTL := $(wildcard ../../rtl/*/*.v) top.v basys3.xdc build.tcl rtl.tcl

.PHONY: all prog gui open clean

all: $(OUT)/top.bit

$(OUT)/top.bit: $(RTL)
	@mkdir -p $(OUT)
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log vivado.log -notrace \
	  -source $(CURDIR)/build.tcl -tclargs $(CURDIR)/$(OUT)

prog: $(OUT)/top.bit
	$(LOADER) -b basys3 $(OUT)/top.bit

gui: $(OUT)/top.bit
	cd $(OUT) && $(VIVADO) -nojournal -nolog $(CURDIR)/$(OUT)/post_route.dcp &

XPR := $(OUT)/proj/m1core_basys3.xpr

$(XPR):
	@mkdir -p $(OUT)
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log project.log -notrace \
	  -source $(CURDIR)/project.tcl -tclargs $(CURDIR)/$(OUT)

open: $(XPR)
	cd $(OUT)/proj && $(VIVADO) -nojournal -nolog $(CURDIR)/$(XPR) &

clean:
	rm -rf $(OUT)

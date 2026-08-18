#!/bin/sh
# logic depth probe for the pipelined core and the soc
#
# a gowin build is hours and this is seconds, which is the whole argument for
# it: structure problems are visible here and chasing them in the place and
# route report is how five builds went missing. it does not predict fmax. it
# tells you when something is shaped wrong.
#
#   sh tools/depth.sh core   technology independent, core only
#   sh tools/depth.sh soc    technology independent, whole soc
#   sh tools/depth.sh lut4   lut4 mapped, core only, adders stubbed
#
# two caveats, both learned the hard way:
#
#   the multiplier is stubbed in every mode. yosys ripples a 32x32 multiply
#   into the netlist where gowin drops in a dsp block, and it then dominates
#   every count and hides everything else.
#
#   the wide adders are stubbed in lut4 mode for the same reason. abc maps a
#   32-bit add to about twenty levels of lut; gowin puts it on dedicated carry
#   logic. leaving them in pins the count at the adder no matter what else
#   changes, which makes the number useless for comparing two revisions.
#
# so: the technology independent count over-counts and chains, because yosys
# keeps a written-out and chain as two-input gates where a lut4 eats four
# inputs at once. it is still the better one for finding priority chains and
# feedback loops. the lut4 count is the better one for comparing before and
# after.

set -e
MODE=${1:-core}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -r "$ROOT/rtl" "$WORK/rtl"

C=$WORK/rtl/pipe/m1core_cpu_p.v
A=$WORK/rtl/pipe/m1core_alu.v

stub () {
  # $1 is a description, $2 the sed script, $3 the file, $4 a grep that must hit
  sed -i "$2" "$3"
  grep -q "$4" "$3" || { echo "depth.sh: $1 stub did not apply, check the pattern" >&2; exit 1; }
}

stub multiplier 's/mul_q  <= e_a \* e_b;/mul_q  <= e_a ^ e_b;/' "$C" 'mul_q  <= e_a \^ e_b'

CORE_SRC="$WORK/rtl/core/m1core_decode.v $C $WORK/rtl/pipe/m1core_fetch.v $A"

case "$MODE" in
  core)
    SCRIPT="read_verilog -DM1CORE_PIPELINE $CORE_SRC;
            hierarchy -top m1core_cpu_p; proc; flatten; opt -full; ltp -noff"
    ;;
  soc)
    # one line per yosys command: a newline inside -p is a command separator,
    # so a file list broken across lines becomes "no such command"
    SOC_SRC="$WORK/rtl/core/m1core_nvic.v \
             $WORK/rtl/mcu/ahb_fabric.v $WORK/rtl/mcu/ahb_sram.v \
             $WORK/rtl/mcu/ahb_arb.v $WORK/rtl/mcu/ahb_apb_bridge.v \
             $WORK/rtl/mcu/m1core_apb.v $WORK/rtl/mcu/m1core_mcu.v \
             $WORK/rtl/debug/swd_phy.v $WORK/rtl/debug/sw_dp.v \
             $WORK/rtl/debug/mem_ap.v $WORK/rtl/debug/ppb_regs.v \
             $WORK/rtl/periph/ahb_gpio.v $WORK/rtl/periph/apb_uart.v \
             $WORK/rtl/periph/apb_timer.v $WORK/rtl/periph/apb_rtc.v \
             $WORK/rtl/periph/apb_spi.v $WORK/rtl/periph/apb_i2c.v"
    SCRIPT="read_verilog -DM1CORE_PIPELINE $CORE_SRC $SOC_SRC;
            hierarchy -top m1core_mcu; proc; flatten; opt -full; ltp -noff"
    ;;
  lut4)
    stub 'alu adder' \
      "s/wire \[32:0\] sum  = {1'b0, a} + {1'b0, addb} + {32'd0, addc_in};/wire [32:0] sum  = {1'b0, a} ^ {1'b0, addb};   \/\/ stubbed by depth.sh/" \
      "$A" 'stubbed by depth.sh'
    stub 'address adder' \
      's/wire \[31:0\] d_addr   = e_a + e_b;/wire [31:0] d_addr   = e_a ^ e_b;/' \
      "$C" 'd_addr   = e_a \^ e_b'
    stub 'branch adder' \
      "s/wire \[31:0\] br_target = x_pc4 + e_boff;/wire [31:0] br_target = x_pc4 ^ e_boff;/" \
      "$C" 'br_target = x_pc4 \^ e_boff'
    SCRIPT="read_verilog -DM1CORE_PIPELINE $CORE_SRC;
            hierarchy -top m1core_cpu_p; proc; flatten; opt -full;
            techmap; opt -full; abc -lut 4; opt_clean; ltp -noff"
    ;;
  *)
    echo "usage: $0 core|soc|lut4" >&2
    exit 2
    ;;
esac

yosys -p "$SCRIPT" 2>&1 \
  | sed -n '/Longest topological/,/^ *ff:/p' \
  | sed "s#$WORK/rtl#rtl#g"

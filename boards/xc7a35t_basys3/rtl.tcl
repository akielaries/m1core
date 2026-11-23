# shared by build.tcl and project.tcl
#
# core selection, `make CORE=multicycle` to override. the pipelined core is the
# default: it runs m1kern on this board about 1.9x faster than the multi-cycle
# reference, since the push/pop stack bank fix (docs/cores.md)
set core pipeline
if {[info exists ::env(CORE)] && $::env(CORE) ne ""} {
  set core $::env(CORE)
}

set rtl {
  rtl/core/m1core_decode.v
  rtl/core/m1core_nvic.v
  rtl/debug/mem_ap.v
  rtl/debug/ppb_regs.v
  rtl/debug/sw_dp.v
  rtl/debug/swd_phy.v
  rtl/mcu/ahb_apb_bridge.v
  rtl/mcu/ahb_arb.v
  rtl/mcu/ahb_sram.v
  rtl/periph/ahb_gpio.v
  rtl/periph/apb_rtc.v
  rtl/periph/apb_timer.v
  rtl/periph/apb_uart.v
}

# this board's soc has an apb expansion slot the shared rtl/mcu files do not,
# so the three generated ones come from boards/xc7a35t_basys3/mcu.yaml (make
# gen), plus the board only peripherals hanging off that slot
lappend rtl \
  boards/xc7a35t_basys3/gen/ahb_fabric.v \
  boards/xc7a35t_basys3/gen/m1core_apb.v \
  boards/xc7a35t_basys3/gen/m1core_mcu.v \
  boards/xc7a35t_basys3/periph/sevenseg_regs.v \
  boards/xc7a35t_basys3/periph/sevenseg.v

switch $core {
  multicycle {
    lappend rtl rtl/core/m1core_cpu.v
    set defines {M1CORE_FORCE_MULTICYCLE}
  }
  pipeline {
    lappend rtl rtl/pipe/m1core_alu.v rtl/pipe/m1core_cpu_p.v rtl/pipe/m1core_fetch.v
    set defines {M1CORE_PIPELINE}
  }
  default {
    error "unknown CORE=$core, use multicycle or pipeline"
  }
}
puts "m1core: $core core"

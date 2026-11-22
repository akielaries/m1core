# shared by build.tcl and project.tcl
#
# core selection, `make CORE=pipeline` to override. multicycle is the default
# because the pipelined core's exception path is not finished (sim/Makefile,
# excp fails 6 of 15) and m1kern hangs on it right after kernel_start
set core multicycle
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
  rtl/mcu/ahb_fabric.v
  rtl/mcu/ahb_sram.v
  rtl/mcu/m1core_apb.v
  rtl/mcu/m1core_mcu.v
  rtl/periph/ahb_gpio.v
  rtl/periph/apb_rtc.v
  rtl/periph/apb_timer.v
  rtl/periph/apb_uart.v
}

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

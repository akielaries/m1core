# shared by build.tcl and project.tcl
# same rtl set as boards/gw5a25/m1core.gprj (pipelined core)
set rtl {
  rtl/core/m1core_decode.v
  rtl/core/m1core_nvic.v
  rtl/pipe/m1core_alu.v
  rtl/pipe/m1core_cpu_p.v
  rtl/pipe/m1core_fetch.v
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

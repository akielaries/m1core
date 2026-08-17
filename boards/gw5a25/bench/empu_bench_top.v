`default_nettype none

// gowin empu m1 in the same harness m1core is measured in
//
// this exists to answer one question that no amount of reading our own timing
// report can: what does a known good arm core reach on this exact part, at
// this speed grade, with this toolchain? every number in HANDOFF.md is
// relative to itself. this one is the ruler.
//
// so the harness matches boards/gw5a25/top.v deliberately, and the things that
// matter are the things that are the same:
//
//   - the same pll, the same instantiation, the same 100 MHz clkout0, so the
//     core is asked for 10 ns exactly as ours is
//   - the same ../timing.sdc, which constrains the 50 MHz pin and lets the
//     tool derive the pll output from the pll's own parameters
//   - the same reset shape: asserted asynchronously, released through two
//     flops in the destination domain
//
// what is NOT the same, and has to be read alongside the number:
//
//   - their m1 arrives as an encrypted netlist that has already been mapped
//     and optimised for this family. ours is rtl the tool sees for the first
//     time. that difference favours them and is not a design flaw in ours
//   - their soc has gpio and one uart. ours also has a timer, an rtc, an spi
//     and an i2c, all of which are on the bus and all of which cost fabric
//   - tcm sizes. the generated .ipc says ITCM_Size=5 and DTCM_Size=5, which
//     are dropdown indices, not kilobytes. read what the ide actually shows
//     and write it in the results table in README.md, because bsram pressure
//     is the current hypothesis for our own placement problem and the
//     comparison is worthless without it

module empu_bench_top (
  input  wire        HCLK,       // 50 MHz oscillator
  input  wire        HRST,       // key, active high on this board

  input  wire        UART0RXD,
  output wire        UART0TXD,

  inout  wire [15:0] GPIO,
  inout  wire        JTAG_7,
  inout  wire        JTAG_9,

  output wire        LOCKUP,
  output wire        HALTED
);

  // ---- the same pll as top.v, 50 x 18 / 9 = 100 MHz on clkout0 ----
  wire clk_sys;
  wire pll_lock;
  wire pll_clk0;

  // mdclk must be a real running clock, not tied off: the generated wrapper
  // feeds it to PLL_INIT and the generator writes defparam CLK_PERIOD = 20
  // into that instance, so it is expecting HCLK
  Gowin_PLL u_pll (
    .clkin   (HCLK),
    .clkout0 (pll_clk0),
    .lock    (pll_lock),
    .mdclk   (HCLK)
  );

  assign clk_sys = pll_clk0;

  // ---- the same reset shape as top.v ----
  //
  // neither HRST nor pll_lock belongs to the clk_sys domain, so the release is
  // a clock domain crossing and gets registered twice in the destination
  // domain. see the round five section of HANDOFF.md for what happens without
  // it, and expect the same two negative removal slacks on rst_sync_* here
  wire rst_n_raw = ~HRST & pll_lock;

  reg [1:0] rst_sync;
  always @(posedge clk_sys or negedge rst_n_raw) begin
    if (!rst_n_raw) begin
      rst_sync <= 2'b00;
    end else begin
      rst_sync <= {rst_sync[0], 1'b1};
    end
  end

  wire rst_n = rst_sync[1];

  Gowin_EMPU_M1_Top u_empu (
    .LOCKUP   (LOCKUP),
    .HALTED   (HALTED),
    .GPIO     (GPIO),
    .JTAG_7   (JTAG_7),
    .JTAG_9   (JTAG_9),
    .UART0RXD (UART0RXD),
    .UART0TXD (UART0TXD),
    .HCLK     (clk_sys),
    .hwRstn   (rst_n)
  );

endmodule

`default_nettype wire

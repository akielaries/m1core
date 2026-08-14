// board layer for the tang primer 25k (GW5A-LV25MG121)
//
// physical pins, clock and reset polarity only. everything else lives in the
// shared m1core_soc, so a second board is a new directory and nothing more
//
//   LED[0] heartbeat, proves the fabric is clocked
//   LED[1] debug power up handshake completed
//   LED[2] debugger attached (C_DEBUGEN set)
//   LED[3] swd traffic flicker
//   GPIO   firmware controlled, blink drives these
//
// this board runs a 50 MHz clock, so a probe at a few MHz is comfortably inside
// the "clk at least 4x swclk" requirement the swd phy needs

module top (
  input        HCLK,      // 50 MHz system clock, ball E2
  input        HRST,      // reset key, ACTIVE HIGH per this board's convention

  input        SWCLK,     // from the black magic probe
  inout        SWDIO,

  output [3:0] LED,
  output [1:0] GPIO,

  output       UART_TX,   // to the usb-uart / a scope
  input        UART_RX
);

  // the soc takes an active low reset, the board key is active high
  wire rst_n = ~HRST;

  // ---------------------------------------------------------------------------
  // system clock: 50 MHz divided by two
  //
  // the core's critical path runs from an instruction bit through ~17 levels of
  // decode straight into the register file write port, and at 50 MHz that left
  // 0.023 ns of slack. it technically met timing, but margin that thin is not
  // worth trusting across voltage and temperature, and any rtl change flips it
  // negative.
  //
  // halving the clock costs nothing that matters here: the core is multi-cycle,
  // so this only halves an already modest instruction rate, and 25 MHz is still
  // 5x the probe's swd clock, well inside the phy's 4x oversampling requirement.
  //
  // the real fix is to register the decode so ST_EXEC is not one giant
  // combinational cone. once that is done this divider can come out
  // ---------------------------------------------------------------------------
  reg clk_sys = 1'b0;

  always @(posedge HCLK) begin
    clk_sys <= ~clk_sys;
  end

  // preloading the itcm is optional and OFF by default.
  //
  // an unresolvable $readmemh path is a hard synthesis error, not a soft
  // fallback, and the working directory GowinSynthesis uses is not something
  // worth guessing at. leaving this empty means the build always succeeds and
  // firmware arrives via gdb load, which is the normal path anyway.
  //
  // to get a blinking led at power up with no probe attached, copy
  // fw/build/blink.hex next to this file and set ITCM_INIT to "blink.hex". if
  // synthesis cannot find it, adjust the path until it does; it is relative to
  // wherever GowinSynthesis runs, not to this file
  m1core_soc #(
    .ITCM_WORDS (4096),          // 16 kb
    .DTCM_WORDS (2048),          // 8 kb
    .GPIO_WIDTH (2),
    .ITCM_INIT  ("")
  ) u_soc (
    .clk   (clk_sys),
    .rst_n (rst_n),
    .swclk (SWCLK),
    .swdio (SWDIO),
    .led   (LED),
    .gpio  (GPIO),
    .uart0_rxd (UART_RX),
    .uart0_txd (UART_TX),
    .uart0_irq ()          // no nvic yet, so this goes nowhere for now
  );

endmodule

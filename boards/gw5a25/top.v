// board layer for the tang primer 25k (GW5A-LV25MG121)
//
// physical pins, clock and reset polarity only. everything else lives in the
// shared m1core_mcu, so a second board is a new directory and nothing more
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

  // ---------------------------------------------------------------------------
  // system clock
  //
  // the divider exists because the design could not make 50 MHz. measured Fmax
  // was 25.697 MHz when the nvic priority selection was a running comparison;
  // as a balanced tree it is 33.394 MHz, which leaves 10 ns of slack at 25 and
  // means the divider is now costing real throughput.
  //
  // define M1CORE_PLL to drive the mcu from a pll instead. generate it in the
  // gowin ide, IP Core Generator > Hard Module > CLOCK > PLL:
  //
  //   input   50 MHz          (HCLK, ball E2)
  //   output  30 MHz          measured Fmax is 33.4, so do not sit on it
  //   name    m1core_pll      or edit the instance below to match
  //
  // check the generated module's port names against this instantiation. the ip
  // generator names them per version and getting them wrong is a build error,
  // not a silent problem, so it is cheap to find.
  //
  // THREE things have to change together or the build is wrong in ways that do
  // not show up until software runs:
  //   1. define M1CORE_PLL for this file
  //   2. mcu.yaml clock.hz, then regenerate. the fabric clock is compiled into
  //      the header as a constant, so a stale value silently breaks the uart
  //      baud divisor and the rtc prescale
  //   3. timing.sdc, see the commented block there
  // ---------------------------------------------------------------------------
`ifdef M1CORE_PLL
  wire clk_sys;
  wire pll_lock;

  m1core_pll u_pll (
    .clkin  (HCLK),
    .clkout (clk_sys),
    .lock   (pll_lock)
  );
`else
  wire pll_lock = 1'b1;
  reg  clk_sys = 1'b0;

  always @(posedge HCLK) begin
    clk_sys <= ~clk_sys;
  end
`endif

  // the soc takes an active low reset, the board key is active high.
  // also held while a pll is still acquiring: releasing reset onto an unlocked
  // clock starts the core fetching against a frequency that is still moving
  wire rst_n = ~HRST & pll_lock;

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
  m1core_mcu #(
    // sized to match the linker scripts. m1kern links for 32k/16k, and if the
    // hardware is smaller the address simply wraps in ahb_sram rather than
    // faulting, so an oversized stack silently aliases onto .data
    .ITCM_WORDS (8192),          // 32 kb
    .DTCM_WORDS (4096),          // 16 kb
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
    .uart0_txd (UART_TX)
  );

endmodule

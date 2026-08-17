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
  // the pll is the design now and needs no define. define M1CORE_DIVIDER to go
  // back to HCLK/2, but note that then nothing instantiates Gowin_PLL, it
  // becomes a top level candidate, and the tool may synthesise it instead of
  // this module: every pin in pins.cst then reports CT1135 "can't find object".
  // set TopModule explicitly and that cannot happen either way.
  //
  // generated in the gowin ide, IP Core Generator > Hard Module > CLOCK > PLL:
  //
  //   Common  > CLKIN 50.000, Enable Lock ticked
  //   Clkout0 > 100 MHz   VCO 50 x MDIV 14 = 700, ODIV0 7
  //
  // one output only. the second one was a fallback frequency that was never
  // used, and regenerating without it is what forced this note to be checked
  // against the ip rather than trusted: it had said 45 MHz and ODIV0 20 for a
  // long time while the hardware ran at 100
  //
  // that 100 is a measuring stick, not a target the design meets. it is set
  // high so the tool reports what it can actually reach instead of stopping
  // once it has met something easy -- every early figure in this project
  // (25.697, 33.394, 44) was measured while the sdc asked for 25 and was
  // therefore a floor, not an Fmax.
  //
  // what it reaches is about 82 MHz, and that is the part rather than the
  // design: gowin's own cortex-m1, the empu m1 ip, was built on this same
  // board through this same pll and came back at 82.009 MHz against m1core's
  // 81.691. see boards/gw5a25/bench/README.md. so a build that closes timing
  // wants clkout0 nearer 80, with the usual margin below the measured ceiling
  // for voltage and temperature.
  //
  // THE FREQUENCY LIVES IN THREE PLACES and they move together or the build is
  // quietly wrong: this pll, mcu.yaml clock.hz (which is compiled into the c
  // header, so a stale value silently breaks the uart baud divisor and the rtc
  // prescale), and timing.sdc. mcu.yaml currently says 45 MHz and the pll says
  // 100, which is open problem 2 in HANDOFF.md
  //
  // the port names below match what that generator emits: module Gowin_PLL
  // with clkin, clkout0 and lock. mdclk is the mdrp clock and only appears if
  // mDRP is enabled under Optional Ports, which it should not be; if the
  // generated module has it anyway, tie it to HCLK. a name that does not match
  // is an elaboration error rather than anything subtle, so it is cheap to
  // find and fix.
  //
  // TWO things have to change together with the pll frequency, or the build is
  // wrong in ways that do not show up until software runs:
  //   1. mcu.yaml clock.hz, then regenerate. the fabric clock is compiled into
  //      the header as a constant, so a stale value silently breaks the uart
  //      baud divisor and the rtc prescale
  //   2. timing.sdc
  // ---------------------------------------------------------------------------
`ifdef M1CORE_DIVIDER
  wire pll_lock = 1'b1;
  reg  clk_sys = 1'b0;

  always @(posedge HCLK) begin
    clk_sys <= ~clk_sys;
  end
`else
  wire clk_sys;
  wire pll_lock;
  wire pll_clk0;

  // one output. there used to be a second at a fallback frequency so that
  // changing speed was a define rather than an ip regeneration, and it was
  // never used: the frequency has to move in mcu.yaml and timing.sdc at the
  // same time anyway, so it was a define that could only ever be wrong.
  //
  // mdclk must be a real running clock, not tied off. the generated wrapper
  // feeds it to PLL_INIT, which clocks the arora v pll's initialisation
  // sequence from it, and the generator writes defparam CLK_PERIOD = 20 into
  // that instance: it is expecting 20 ns, which is HCLK. tied low the pll
  // never initialises
  Gowin_PLL u_pll (
    .clkin   (HCLK),
    .clkout0 (pll_clk0),
    .lock    (pll_lock),
    .mdclk   (HCLK)
  );

  assign clk_sys = pll_clk0;

`endif

  // the soc takes an active low reset, the board key is active high.
  // also held while a pll is still acquiring: releasing reset onto an unlocked
  // clock starts the core fetching against a frequency that is still moving
  wire rst_n_raw = ~HRST & pll_lock;

  // ---- reset deassertion is synchronised to clk_sys ----
  //
  // neither source of rst_n_raw belongs to this clock domain. HRST is a key on
  // a pin, and pll_lock comes out of the pll's init sequencer, which the
  // generated wrapper clocks from mdclk -- HCLK, the 50 MHz oscillator, not
  // the 100 MHz output. so releasing reset is a clock domain crossing, and the
  // sta report called it: six hold violations, every one of them
  // `Launch Clk HCLK` / `Latch Clk CLKOUT0` landing on the sequencer's control
  // registers. those registers take their reset through the enable path rather
  // than a dedicated clear, which is why they got a hold check at all and the
  // rest of the core did not; the ones that did not are not safe either, they
  // are just not checked.
  //
  // a hold violation does not go away by slowing the clock down. the flops
  // would come out of reset on different cycles, or metastable, and the core
  // would start from a state no simulation covers.
  //
  // asserting asynchronously is what a reset is for, so that stays. only the
  // release is registered, twice, in the destination domain
  reg [1:0] rst_sync;
  always @(posedge clk_sys or negedge rst_n_raw) begin
    if (!rst_n_raw) begin
      rst_sync <= 2'b00;
    end else begin
      rst_sync <= {rst_sync[0], 1'b1};
    end
  end

  wire rst_n = rst_sync[1];

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

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

// no pll: the oscillator is 50 MHz and mcu.yaml clock.hz is 50000000, so the
// fabric runs straight off HCLK and the design has ONE clock domain. changing
// clock.hz means putting a pll back
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

  // the board key is ACTIVE HIGH -- pulled down, reads high when pressed -- so
  // the asynchronous reset is its inverse. wiring HRST straight to rst_n holds
  // the core in reset whenever the key is NOT pressed, and m1core_mcu ands it
  // with its power on reset, so nothing downstream can rescue it
  wire key_n = ~HRST;

  // ---- reset: asynchronous assert from the key, synchronous release ----
  //
  // every flop in the soc resets on `negedge rst_n`, so releasing an async pin
  // directly lets them leave reset on different edges. the mcu's power on reset
  // covers power up but not a key press, which is what this is for.
  //
  // the pll used to shift in through here as data; with no pll there is no lock
  // to wait for, so it shifts in a constant
  reg [1:0] rst_sync;
  always @(posedge HCLK or negedge key_n) begin
    if (!key_n) begin
      rst_sync <= 2'b00;
    end else begin
      rst_sync <= {rst_sync[0], 1'b1};
    end
  end

  wire rst_n = rst_sync[1];

  // ITCM_INIT is off by default: an unresolvable $readmemh path is a hard
  // synthesis error, and the directory GowinSynthesis runs in is not worth
  // guessing at. firmware arrives via gdb load. for a blinking led with no
  // probe, copy fw/build/blink.hex next to this file and name it here
  m1core_mcu #(
    // sized to match the linker scripts. if the hardware is smaller the address
    // wraps in ahb_sram rather than faulting, so an oversized stack silently
    // aliases onto .data
    .ITCM_WORDS (8192),          // 32 kb
    .DTCM_WORDS (4096),          // 16 kb
    .GPIO_WIDTH (2),
    .ITCM_INIT  ("")
  ) u_soc (
    .clk   (HCLK),
    .rst_n (rst_n),
    .swclk (SWCLK),
    .swdio (SWDIO),
    .led   (LED),
    .gpio  (GPIO),
    .uart0_rxd (UART_RX),
    .uart0_txd (UART_TX)
  );

endmodule

// board layer for the digilent basys 3 (XC7A35T-1CPG236C)
//
// physical pins, clock and reset only. the soc is the shared m1core_mcu
//
//   led[3:0] the mcu's swd bring-up staircase, see m1core_mcu.v:
//     led[0] heartbeat, proves the fabric is clocked
//     led[1] swclk edges are arriving at the pin
//     led[2] a line reset was recognised (sticky)
//     led[3] a well formed packet was decoded (sticky)
//   led[5:4] gpio0, firmware controlled (blink drives these)
//   led[6]   raw SWDIO level, should idle lit (pulled up / driven high)
//   led[7]   raw SWCLK level, should idle dark
//   led[15]  mmcm locked
//
// swd is on pmod JA (JA1 = SWCLK, JA2 = SWDIO, pin 5 = GND, pin 6 = 3V3) for a black
// magic probe. uart0 is the onboard ft2232 channel B, so `load` over swd and
// printf over the same usb cable that programs the fpga

module top (
  input         clk,        // 100 MHz oscillator, W5
  input         btnC,       // centre button, active high reset

  input         SWCLK,
  inout         SWDIO,

  output [15:0] led,
  output [3:0]  an,         // 7-seg anodes, held off

  output        uart_tx,    // fpga -> host
  input         uart_rx     // host -> fpga
);

  // ---- 100 MHz -> 50 MHz, matching mcu.yaml clock.hz and SYSTEM_CLOCK_HZ ----
  wire clk_fb, clk_fb_buf, clk_50_unbuf, clk_50, mmcm_locked;

  MMCME2_BASE #(
    .CLKIN1_PERIOD(10.0),
    .CLKFBOUT_MULT_F(10.0),
    .CLKOUT0_DIVIDE_F(20.0)
  ) u_mmcm (
    .CLKIN1(clk),
    .CLKFBIN(clk_fb_buf),
    .CLKFBOUT(clk_fb),
    .CLKOUT0(clk_50_unbuf),
    .LOCKED(mmcm_locked),
    .RST(1'b0),
    .PWRDWN(1'b0),
    .CLKFBOUTB(),
    .CLKOUT0B(),
    .CLKOUT1(),
    .CLKOUT1B(),
    .CLKOUT2(),
    .CLKOUT2B(),
    .CLKOUT3(),
    .CLKOUT3B(),
    .CLKOUT4(),
    .CLKOUT5(),
    .CLKOUT6()
  );

  BUFG u_fb_bufg (.I(clk_fb), .O(clk_fb_buf));
  BUFG u_clk_bufg (.I(clk_50_unbuf), .O(clk_50));

  // ---- reset: async assert from the button or mmcm unlock, sync release ----
  wire arst_n = ~btnC & mmcm_locked;

  reg [1:0] rst_sync;
  always @(posedge clk_50 or negedge arst_n) begin
    if (!arst_n) begin
      rst_sync <= 2'b00;
    end else begin
      rst_sync <= {rst_sync[0], 1'b1};
    end
  end

  wire rst_n = rst_sync[1];

  wire [3:0] dbg_led;
  wire [1:0] gpio;

  m1core_mcu #(
    .ITCM_WORDS (8192),          // 32 kb, matches the linker scripts
    .DTCM_WORDS (4096),          // 16 kb
    .GPIO_WIDTH (2),
    .ITCM_INIT  ("")
  ) u_soc (
    .clk       (clk_50),
    .rst_n     (rst_n),
    .swclk     (SWCLK),
    .swdio     (SWDIO),
    .led       (dbg_led),
    .gpio      (gpio),
    .uart0_rxd (uart_rx),
    .uart0_txd (uart_tx)
  );

  // basys 3 leds are active high
  assign led[3:0]   = dbg_led;
  assign led[5:4]   = gpio;
  assign led[6]     = SWDIO;
  assign led[7]     = SWCLK;
  assign led[14:8]  = 7'b0;
  assign led[15]    = mmcm_locked;
  assign an         = 4'b1111;

endmodule

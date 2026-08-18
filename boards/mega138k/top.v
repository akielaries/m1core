// board layer for the tang mega 138k (GW5AST-LV138FPG676AC2/I1)
//
// physical pins, clock and reset polarity only. everything else lives in the
// shared m1core_mcu.
//
// hwRstn is ACTIVE LOW here. the 25k has a key pulled down and inverts in its
// board layer; this one does not. backwards gives a board that never leaves
// reset or never enters it, and both look like a dead bitstream

module top (
  input        HCLK,          // 50 MHz system clock, ball P16
  input        hwRstn,        // reset, ACTIVE LOW on this board, ball K16

  input        JTAG_9_SWDCLK, // from the black magic probe
  inout        JTAG_7_SWDIO,

  output       BOOT_LED_A,    // heartbeat, proves the fabric is clocked
  output [1:0] GPIO,          // firmware controlled, blink drives these

  output       UART1TXD,
  input        UART1RXD
);

  // ---- system clock ----
  //
  // generate the pll in the gowin ide for THIS device, into
  // boards/mega138k/src/gowin_pll/, and list only that copy in this board's
  // project: the ip generator writes into whichever project is open, so a
  // copy shared by two projects gives EX3794 duplicate module name
  wire clk_sys;
  wire pll_lock;
  wire pll_clk0;

  // GW5AST, so the wrapper has init_clk and NO mdclk. the port list is device
  // and options specific and cannot be copied from another board;
  // tools/check_pll.py compares it against the wrapper on disk. init_clk must
  // be a real running clock: the wrapper feeds it to PLL_INIT
  Gowin_PLL u_pll (
    .clkin    (HCLK),
    .init_clk (HCLK),
    .clkout0  (pll_clk0),
    .enclk0   (1'b1),
    .lock     (pll_lock),
    .reset    (1'b0)
  );

  assign clk_sys = pll_clk0;


  // ---- reset: asynchronous assert from the key, synchronous release ----
  //
  // only the KEY is asynchronous. pll_lock goes in as data rather than as part
  // of the reset, which trades two removal slacks on rst_sync_*/CLEAR for one
  // hold slack on rst_sync_0/D. before lock there is no clock to shift with,
  // so rst_sync cannot leave zero
  reg [1:0] rst_sync;
  always @(posedge clk_sys or negedge hwRstn) begin
    if (!hwRstn) begin
      rst_sync <= 2'b00;
    end else begin
      rst_sync <= {rst_sync[0], pll_lock};
    end
  end

  wire rst_n = rst_sync[1];

  wire [3:0] led;
  assign BOOT_LED_A = led[0];

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
    .swclk (JTAG_9_SWDCLK),
    .swdio (JTAG_7_SWDIO),
    .led   (led),
    .gpio  (GPIO),
    .uart0_rxd (UART1RXD),
    .uart0_txd (UART1TXD)
  );

endmodule

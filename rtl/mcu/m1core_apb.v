`default_nettype none

// m1core apb subsystem
//
// GENERATED from boards/gw5a25/mcu.yaml by tools/m1core_gen.py. Do not edit.
// Add a peripheral to the MCU description and regenerate.
//
// One AHB slot feeds this no matter how many peripherals hang off it,
// which is why the fabric decode does not grow as the system does.

module m1core_apb (
  input  wire        clk,
  input  wire        rst_n,

  // apb slave side, from ahb_apb_bridge
  input  wire        psel,
  input  wire        penable,
  input  wire        pwrite,
  input  wire [31:0] paddr,
  input  wire [31:0] pwdata,
  output reg  [31:0] prdata,
  output reg         pready,

  // interrupt vector, one bit per irq number
  output wire [31:0] irq,

  // uart0
  input  wire        uart0_rxd,
  output wire        uart0_txd
);

  // address decode. the apb window base is stripped by the fabric, so the
  // comparison is on the offset within it
  wire sel_timer0 = (paddr[27:12] == 16'h0000);
  wire sel_rtc = (paddr[27:12] == 16'h0006);
  wire sel_uart0 = (paddr[27:12] == 16'h0004);

  wire [31:0] prdata_timer0;
  wire        pready_timer0;
  wire [31:0] prdata_rtc;
  wire        pready_rtc;
  wire [31:0] prdata_uart0;
  wire        pready_uart0;

  wire irq_timer0;
  wire irq_rtc;
  wire irq_uart0;

  // read data and ready mux
  always @(*) begin
    prdata = 32'd0;
    pready = 1'b1;
    if (sel_timer0) begin
      prdata = prdata_timer0;
      pready = pready_timer0;
    end
    if (sel_rtc) begin
      prdata = prdata_rtc;
      pready = pready_rtc;
    end
    if (sel_uart0) begin
      prdata = prdata_uart0;
      pready = pready_uart0;
    end
  end

  // interrupt vector. unused lines tie low
  assign irq = {25'd0, irq_rtc, 3'd0, irq_timer0, 1'd0, irq_uart0};

  apb_timer u_timer0 (
    .clk     (clk),
    .rst_n   (rst_n),
    .psel    (psel && sel_timer0),
    .penable (penable),
    .pwrite  (pwrite),
    .paddr   (paddr),
    .pwdata  (pwdata),
    .prdata  (prdata_timer0),
    .pready  (pready_timer0),
    .irq     (irq_timer0)
  );

  apb_rtc u_rtc (
    .clk     (clk),
    .rst_n   (rst_n),
    .psel    (psel && sel_rtc),
    .penable (penable),
    .pwrite  (pwrite),
    .paddr   (paddr),
    .pwdata  (pwdata),
    .prdata  (prdata_rtc),
    .pready  (pready_rtc),
    .irq     (irq_rtc)
  );

  apb_uart u_uart0 (
    .clk     (clk),
    .rst_n   (rst_n),
    .psel    (psel && sel_uart0),
    .penable (penable),
    .pwrite  (pwrite),
    .paddr   (paddr),
    .pwdata  (pwdata),
    .prdata  (prdata_uart0),
    .pready  (pready_uart0),
    .rxd     (uart0_rxd),
    .txd     (uart0_txd),
    .irq     (irq_uart0)
  );

endmodule

`default_nettype wire

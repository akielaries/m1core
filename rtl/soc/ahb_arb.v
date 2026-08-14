`default_nettype none

// two master ahb-lite arbiter, fixed priority
//
// master 0 is the debugger's mem-ap and always wins. that is the behaviour you
// want: a debugger access is rare, must never be starved, and the core is
// usually halted anyway when the debugger is touching memory
//
// there are no bursts and hready is always high, so a transfer is exactly two
// cycles. the arbiter only has to remember who won the address phase so it can
// route hwdata during the following data phase

module ahb_arb (
  input  wire        clk,
  input  wire        rst_n,

  // master 0, the debug access port
  input  wire        m0_req,
  input  wire [31:0] m0_addr,
  input  wire        m0_write,
  input  wire [2:0]  m0_size,
  input  wire [31:0] m0_wdata,
  output wire        m0_gnt,

  // master 1, the cpu
  input  wire        m1_req,
  input  wire [31:0] m1_addr,
  input  wire        m1_write,
  input  wire [2:0]  m1_size,
  input  wire [31:0] m1_wdata,
  output wire        m1_gnt,

  // slave side
  output reg  [31:0] haddr,
  output reg         hwrite,
  output reg  [2:0]  hsize,
  output reg  [1:0]  htrans,
  output wire [2:0]  hburst,
  output wire [3:0]  hprot,
  output wire [31:0] hwdata,
  input  wire        hready
);

  localparam [1:0] HTRANS_IDLE   = 2'b00;
  localparam [1:0] HTRANS_NONSEQ = 2'b10;

  assign m0_gnt = m0_req && hready;
  assign m1_gnt = m1_req && !m0_req && hready;

  always @(*) begin
    if (m0_req) begin
      haddr  = m0_addr;
      hwrite = m0_write;
      hsize  = m0_size;
      htrans = HTRANS_NONSEQ;
    end else if (m1_req) begin
      haddr  = m1_addr;
      hwrite = m1_write;
      hsize  = m1_size;
      htrans = HTRANS_NONSEQ;
    end else begin
      haddr  = 32'd0;
      hwrite = 1'b0;
      hsize  = 3'd2;
      htrans = HTRANS_IDLE;
    end
  end

  // who owns the data phase now, so write data comes from the right master
  reg owner_d;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      owner_d <= 1'b0;
    end else if (m0_gnt) begin
      owner_d <= 1'b0;
    end else if (m1_gnt) begin
      owner_d <= 1'b1;
    end
  end

  assign hwdata = owner_d ? m1_wdata : m0_wdata;
  assign hburst = 3'd0;
  assign hprot  = 4'b0011;

endmodule

`default_nettype wire

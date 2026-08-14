`default_nettype none

// ahb-lite to apb bridge
//
// this is what keeps the ahb fabric from growing a slave per peripheral. no
// matter how many peripherals hang off the apb side, the ahb fabric sees one
// slot and its decode and read mux stay the size they are today. that matters
// because that mux already feeds the path nearest the timing limit
//
// apb also makes peripherals much easier to write: no pipelined address and
// data phase, just a select, an enable and a register file
//
// timing, three cycles per access:
//   cycle 0  ahb address phase, latch address and direction
//   cycle 1  apb setup,  psel=1 penable=0. hwdata is valid now for a write
//   cycle 2  apb access, psel=1 penable=1. completes when pready is high
//
// hreadyout is low from the moment the data phase starts until the apb access
// completes, which is why the fabric and both bus masters had to learn about
// wait states before this block could exist

module ahb_apb_bridge (
  input  wire        clk,
  input  wire        rst_n,

  // ahb-lite slave
  input  wire        hsel,
  input  wire [31:0] haddr,
  input  wire        hwrite,
  input  wire [1:0]  htrans,
  input  wire        hready,
  input  wire [31:0] hwdata,
  output wire [31:0] hrdata,
  output wire        hreadyout,

  // apb master
  output reg         psel,
  output reg         penable,
  output reg         pwrite,
  output reg  [31:0] paddr,
  output wire [31:0] pwdata,
  input  wire [31:0] prdata,
  input  wire        pready
);

  localparam [1:0] ST_IDLE   = 2'd0;
  localparam [1:0] ST_SETUP  = 2'd1;
  localparam [1:0] ST_ACCESS = 2'd2;

  reg [1:0] state;

  wire addr_phase = hsel && hready && htrans[1];

  // hwdata is presented by the master during the data phase, which is exactly
  // when the bridge is in setup and access, so it can be passed straight through
  assign pwdata = hwdata;
  assign hrdata = prdata;

  // ready in idle so a new address phase can start, and ready in the cycle the
  // apb slave completes so the master samples prdata on the same edge
  assign hreadyout = (state == ST_IDLE) || (state == ST_ACCESS && pready);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= ST_IDLE;
      psel    <= 1'b0;
      penable <= 1'b0;
      pwrite  <= 1'b0;
      paddr   <= 32'd0;
    end else begin
      case (state)
        ST_IDLE: begin
          penable <= 1'b0;
          if (addr_phase) begin
            psel   <= 1'b1;
            pwrite <= hwrite;
            paddr  <= haddr;
            state  <= ST_SETUP;
          end else begin
            psel <= 1'b0;
          end
        end

        ST_SETUP: begin
          penable <= 1'b1;
          state   <= ST_ACCESS;
        end

        ST_ACCESS: begin
          if (pready) begin
            psel    <= 1'b0;
            penable <= 1'b0;
            state   <= ST_IDLE;
          end
        end

        default: begin
          state <= ST_IDLE;
        end
      endcase
    end
  end

endmodule

`default_nettype wire

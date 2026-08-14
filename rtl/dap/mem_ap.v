`default_nettype none

// adiv5 mem-ap with an ahb-lite master
//
// ap register addresses arrive as {apbanksel, haddr[3:2]}, so the byte address
// of each register is {ap_addr, 2'b00}:
//   0x00 csw   0x04 tar   0x0c drw   0x10-0x1c bd0-3
//   0xf4 cfg   0xf8 base  0xfc idr
//
// this is the block that turns a debugger's drw access into a real bus cycle,
// which is how gdb load gets firmware into memory

module mem_ap #(
  parameter [31:0] IDR_VALUE  = 32'h2477_0011,
  parameter [31:0] BASE_VALUE = 32'he00f_f003
) (
  input  wire        clk,
  input  wire        rst_n,

  // debug port side
  input  wire        ap_req,
  input  wire        ap_rnw,
  input  wire [7:0]  ap_sel,
  input  wire [5:0]  ap_addr,
  input  wire [31:0] ap_wdata,
  output reg         ap_ack,
  output reg  [31:0] ap_rdata,
  output reg         ap_fault,

  // ahb-lite master through the arbiter
  output reg         bus_req,
  output reg  [31:0] bus_addr,
  output reg         bus_write,
  output reg  [2:0]  bus_size,
  output reg  [31:0] bus_wdata,
  input  wire        bus_gnt,
  input  wire [31:0] hrdata,
  input  wire        hresp
);

  localparam [5:0] AP_CSW  = 6'h00;
  localparam [5:0] AP_TAR  = 6'h01;
  localparam [5:0] AP_DRW  = 6'h03;
  localparam [5:0] AP_BD0  = 6'h04;
  localparam [5:0] AP_BD3  = 6'h07;
  localparam [5:0] AP_CFG  = 6'h3d;
  localparam [5:0] AP_BASE = 6'h3e;
  localparam [5:0] AP_IDR  = 6'h3f;

  // state encoding, was a typedef enum before the verilog 2001 down-convert
  localparam [1:0] ST_IDLE = 2'd0;
  localparam [1:0] ST_ADDR = 2'd1;
  localparam [1:0] ST_DATA = 2'd2;

  reg [1:0] state;

  reg [31:0] tar;
  reg [2:0]  csw_size;
  reg [1:0]  csw_addrinc;
  reg [6:0]  csw_prot;
  reg        csw_dbgswen;

  reg [31:0] xfer_wdata;
  reg        xfer_is_drw;

  // this design has exactly one ap, at apsel 0
  wire ap_here   = (ap_sel == 8'd0);

  wire is_banked = (ap_addr >= AP_BD0) && (ap_addr <= AP_BD3);
  wire is_mem    = (ap_addr == AP_DRW) || is_banked;

  // banked accesses hit a fixed window around tar and never auto increment
  wire [31:0] banked_addr = {tar[31:4], ap_addr[1:0], 2'b00};

  wire [31:0] csw_value = {
    csw_dbgswen,   // 31 dbgswenable
    csw_prot,      // 30:24 prot
    1'b0,          // 23 spiden
    7'd0,          // 22:16
    4'd0,          // 15:12
    4'd0,          // 11:8 mode
    1'b0,          // 7 trinprog
    1'b1,          // 6 deviceen
    csw_addrinc,   // 5:4
    1'b0,          // 3
    csw_size       // 2:0
  };

  // number of bytes consumed by the current access, for auto increment
  wire [3:0] size_bytes = (csw_size == 3'd0) ? 4'd1 :
                          (csw_size == 3'd1) ? 4'd2 : 4'd4;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= ST_IDLE;
      ap_ack      <= 1'b0;
      ap_rdata    <= 32'd0;
      ap_fault    <= 1'b0;
      tar         <= 32'd0;
      csw_size    <= 3'd2;
      csw_addrinc <= 2'd0;
      csw_prot    <= 7'd0;
      csw_dbgswen <= 1'b1;
      xfer_wdata  <= 32'd0;
      xfer_is_drw <= 1'b0;
      bus_req     <= 1'b0;
      bus_addr    <= 32'd0;
      bus_write   <= 1'b0;
      bus_size    <= 3'd2;
      bus_wdata   <= 32'd0;
    end else begin
      ap_ack   <= 1'b0;
      ap_fault <= 1'b0;

      case (state)
        ST_IDLE: begin
          if (ap_req) begin
            if (!ap_here) begin
              // nothing lives at this apsel. answering with zeroes makes IDR
              // read 0, which is how a probe decides an ap is absent. without
              // this the single ap answers at all 256 apsel values and the
              // probe enumerates 256 identical targets
              ap_ack   <= 1'b1;
              ap_rdata <= 32'd0;
            end else if (is_mem) begin
              // ask the arbiter for the bus, the address phase happens when it
              // grants
              bus_req     <= 1'b1;
              bus_addr    <= is_banked ? banked_addr : tar;
              bus_write   <= !ap_rnw;
              bus_size    <= csw_size;
              bus_wdata   <= ap_wdata;
              xfer_wdata  <= ap_wdata;
              xfer_is_drw <= !is_banked;
              state       <= ST_ADDR;
            end else begin
              // register access, answers immediately
              ap_ack <= 1'b1;
              if (ap_rnw) begin
                case (ap_addr)
                  AP_CSW:  ap_rdata <= csw_value;
                  AP_TAR:  ap_rdata <= tar;
                  AP_CFG:  ap_rdata <= 32'd0;
                  AP_BASE: ap_rdata <= BASE_VALUE;
                  AP_IDR:  ap_rdata <= IDR_VALUE;
                  default: ap_rdata <= 32'd0;
                endcase
              end else begin
                case (ap_addr)
                  AP_CSW: begin
                    csw_dbgswen <= ap_wdata[31];
                    csw_prot    <= ap_wdata[30:24];
                    csw_addrinc <= ap_wdata[5:4];
                    csw_size    <= ap_wdata[2:0];
                  end
                  AP_TAR: begin
                    tar <= ap_wdata;
                  end
                  default: begin
                  end
                endcase
              end
            end
          end
        end

        // waiting for the arbiter, the address phase is the granted cycle
        ST_ADDR: begin
          if (bus_gnt) begin
            bus_req <= 1'b0;
            state   <= ST_DATA;
          end
        end

        // data phase, hrdata is valid here for a read
        ST_DATA: begin
          ap_ack   <= 1'b1;
          ap_rdata <= hrdata;
          ap_fault <= hresp;
          state    <= ST_IDLE;
          // auto increment applies to drw only, never to the banked registers
          if (xfer_is_drw && csw_addrinc == 2'd1) begin
            tar <= tar + {28'd0, size_bytes};
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

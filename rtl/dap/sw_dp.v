`default_nettype none

// serial wire debug port, adiv5 dpv1
//
// dpv1 is deliberate: it avoids having to implement the dormant state and
// targetsel that dpv2 multidrop requires, and bmp is happy with either
//
// the ack for a write is driven before the write data arrives on the wire, so
// acceptance is decided from the request alone and the data is applied later
// when the phy reports the data phase complete

module sw_dp #(
  parameter [31:0] DPIDR_VALUE = 32'h0c10_1477
) (
  input  wire        clk,
  input  wire        rst_n,

  // from the phy
  input  wire        req_valid,
  input  wire        req_apndp,
  input  wire        req_rnw,
  input  wire [1:0]  req_addr,
  output reg  [2:0]  rsp_ack,
  output reg  [31:0] rsp_rdata,
  input  wire        wr_valid,
  input  wire        wr_parity_ok,
  input  wire [31:0] wr_data,
  input  wire        line_reset,

  // access port interface, ap_addr is register address bits [7:2]
  output reg         ap_req,
  output reg         ap_rnw,
  output wire [7:0]  ap_sel,
  output wire [5:0]  ap_addr,
  output reg  [31:0] ap_wdata,
  input  wire        ap_ack,
  input  wire [31:0] ap_rdata,
  input  wire        ap_fault,

  // power and reset control back to the soc
  output wire        dbg_pwrup,
  output wire        sys_pwrup,
  output wire        dbg_reset_req
);

  localparam [2:0] ACK_OK    = 3'b001;
  localparam [2:0] ACK_WAIT  = 3'b010;
  localparam [2:0] ACK_FAULT = 3'b100;

  // ctrl/stat
  reg csyspwrupreq, cdbgpwrupreq, cdbgrstreq;
  reg stickyerr, stickycmp, stickyorun, orundetect;
  reg wdataerr, readok;
  reg [1:0] trnmode;

  // select
  reg [7:0] apsel;
  reg [3:0] apbanksel;
  reg [3:0] dpbanksel;

  reg [31:0] rdbuff;
  reg        ap_busy;

  // pending write bookkeeping
  reg       await_wr;
  reg       await_wr_apndp;
  reg [1:0] await_wr_addr;

  // latched at request time so the ap address stays valid for a write, whose
  // data phase completes well after the request has gone by
  reg [1:0] ap_addr_lo;

  assign dbg_pwrup     = cdbgpwrupreq;
  assign sys_pwrup     = csyspwrupreq;
  assign dbg_reset_req = cdbgrstreq;

  assign ap_sel  = apsel;
  assign ap_addr = {apbanksel, ap_addr_lo};

  // power up acks mirror the requests, there is no real power domain to sequence
  wire [31:0] ctrlstat = {
    csyspwrupreq,   // 31 csyspwrupack
    csyspwrupreq,   // 30 csyspwrupreq
    cdbgpwrupreq,   // 29 cdbgpwrupack
    cdbgpwrupreq,   // 28 cdbgpwrupreq
    cdbgrstreq,     // 27 cdbgrstack
    cdbgrstreq,     // 26 cdbgrstreq
    2'b00,          // 25:24 res0
    12'd0,          // 23:12 trncnt
    4'd0,           // 11:8  masklane
    wdataerr,       // 7
    readok,         // 6
    stickyerr,      // 5
    stickycmp,      // 4
    trnmode,        // 3:2
    stickyorun,     // 1
    orundetect      // 0
  };

  // an ap access needs debug power up and a clean sticky error state
  wire ap_allowed = cdbgpwrupreq && !stickyerr;

  always @(*) begin
    if (!req_apndp) begin
      rsp_ack = ACK_OK;
    end else if (!ap_allowed) begin
      rsp_ack = ACK_FAULT;
    end else if (ap_busy) begin
      rsp_ack = ACK_WAIT;
    end else begin
      rsp_ack = ACK_OK;
    end
  end

  // ap reads are posted, the value returned is the previous read result
  always @(*) begin
    if (req_apndp) begin
      rsp_rdata = rdbuff;
    end else begin
      case (req_addr)
        2'b00:   rsp_rdata = DPIDR_VALUE;
        2'b01:   rsp_rdata = (dpbanksel == 4'd0) ? ctrlstat : 32'd0;
        2'b10:   rsp_rdata = rdbuff;              // resend
        default: rsp_rdata = rdbuff;              // rdbuff
      endcase
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      csyspwrupreq   <= 1'b0;
      cdbgpwrupreq   <= 1'b0;
      cdbgrstreq     <= 1'b0;
      stickyerr      <= 1'b0;
      stickycmp      <= 1'b0;
      stickyorun     <= 1'b0;
      orundetect     <= 1'b0;
      wdataerr       <= 1'b0;
      readok         <= 1'b0;
      trnmode        <= 2'b00;
      apsel          <= 8'd0;
      apbanksel      <= 4'd0;
      dpbanksel      <= 4'd0;
      rdbuff         <= 32'd0;
      ap_busy        <= 1'b0;
      await_wr       <= 1'b0;
      await_wr_apndp <= 1'b0;
      await_wr_addr  <= 2'b00;
      ap_addr_lo     <= 2'b00;
      ap_req         <= 1'b0;
      ap_rnw         <= 1'b0;
      ap_wdata       <= 32'd0;
    end else begin
      ap_req <= 1'b0;

      // a line reset clears the sticky state and any half finished transfer,
      // but per the spec it must not clear the power up request bits
      if (line_reset) begin
        await_wr   <= 1'b0;
        stickyerr  <= 1'b0;
        stickyorun <= 1'b0;
      end

      if (req_valid) begin
        ap_addr_lo <= req_addr;
        if (!req_rnw && rsp_ack == ACK_OK) begin
          // remember where the data phase should land
          await_wr       <= 1'b1;
          await_wr_apndp <= req_apndp;
          await_wr_addr  <= req_addr;
        end else if (req_rnw && req_apndp && rsp_ack == ACK_OK) begin
          // launch the posted read, the result lands in rdbuff
          ap_req  <= 1'b1;
          ap_rnw  <= 1'b1;
          ap_busy <= 1'b1;
        end
      end

      if (wr_valid) begin
        await_wr <= 1'b0;
        if (!wr_parity_ok) begin
          // a parity error on the data phase is a write data error, not a
          // general sticky error
          wdataerr <= 1'b1;
        end else if (await_wr) begin
          if (await_wr_apndp) begin
            ap_req   <= 1'b1;
            ap_rnw   <= 1'b0;
            ap_wdata <= wr_data;
            ap_busy  <= 1'b1;
          end else begin
            case (await_wr_addr)
              // abort
              2'b00: begin
                if (wr_data[1]) stickycmp  <= 1'b0;
                if (wr_data[2]) stickyerr  <= 1'b0;
                if (wr_data[3]) wdataerr   <= 1'b0;
                if (wr_data[4]) stickyorun <= 1'b0;
                if (wr_data[0]) begin
                  ap_busy <= 1'b0;
                end
              end
              // ctrl/stat
              2'b01: begin
                if (dpbanksel == 4'd0) begin
                  csyspwrupreq <= wr_data[30];
                  cdbgpwrupreq <= wr_data[28];
                  cdbgrstreq   <= wr_data[26];
                  trnmode      <= wr_data[3:2];
                  orundetect   <= wr_data[0];
                end
              end
              // select
              2'b10: begin
                apsel     <= wr_data[31:24];
                apbanksel <= wr_data[7:4];
                dpbanksel <= wr_data[3:0];
              end
              default: begin
              end
            endcase
          end
        end
      end

      if (ap_ack) begin
        ap_busy <= 1'b0;
        if (ap_rnw) begin
          rdbuff <= ap_rdata;
          readok <= !ap_fault;
        end
        if (ap_fault) begin
          stickyerr <= 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire

`default_nettype none

// swd physical layer and packet framer
//
// swclk is an input clock driven by the probe, asynchronous to clk. rather than
// treating it as a clock domain we oversample it with clk and detect edges, so
// no global clock resource is spent and there is no cdc between two real domains
// clk must run at least 4x swclk
//
// clock numbering used throughout, per adiv5:
//   clocks 1-8   request, host driven, sampled on rising edges R1..R8
//   clock  9     turnaround
//   clocks 10-12 ack, target driven, driven on falling edges F9..F11
//   read:  clocks 13-45 data+parity target driven on F12..F44, then turnaround
//   write: clock 13 turnaround, clocks 14-46 data+parity host driven, R14..R46
//
// the host samples on rising edges, so the target must update swdio on falling
// edges. every drive below therefore happens in the falling edge block

module swd_phy #(
  parameter RESET_CYCLES = 50
) (
  input  wire        clk,
  input  wire        rst_n,

  // swd pins, swdio is a tristate at the pad
  input  wire        swclk_i,
  input  wire        swdio_i,
  output reg         swdio_o,
  output reg         swdio_oe,

  // request, pulsed once the 8 bit packet request has been validated
  output reg         req_valid,
  output reg         req_apndp,
  output reg         req_rnw,
  output reg  [1:0]  req_addr,

  // response, must be stable within one swclk period of req_valid
  input  wire [2:0]  rsp_ack,
  input  wire [31:0] rsp_rdata,

  // write data phase, pulsed once 32 bits plus parity have been received
  output reg         wr_valid,
  output reg         wr_parity_ok,
  output reg  [31:0] wr_data,
  output reg         line_reset
);

  localparam [2:0] ACK_OK = 3'b001;

  // state encoding, was a typedef enum before the verilog 2001 down-convert
  localparam [3:0] ST_IDLE = 4'd0;
  localparam [3:0] ST_REQ = 4'd1;
  localparam [3:0] ST_REQ_CHK = 4'd2;
  localparam [3:0] ST_TRN_A = 4'd3;
  localparam [3:0] ST_ACK = 4'd4;
  localparam [3:0] ST_RDATA = 4'd5;
  localparam [3:0] ST_RTRN = 4'd6;
  localparam [3:0] ST_TRN_END = 4'd7;
  localparam [3:0] ST_WREL = 4'd8;
  localparam [3:0] ST_WSKIP = 4'd9;
  localparam [3:0] ST_WDATA = 4'd10;
  localparam [3:0] ST_WDONE = 4'd11;
  localparam [3:0] ST_NAK_REL = 4'd12;

  reg [3:0] state;

  // swclk/swdio synchronisers and edge detect
  reg [2:0] swclk_sync;
  reg [1:0] swdio_sync;
  wire       swclk_rise, swclk_fall, swdio_s;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      swclk_sync <= 3'b000;
      swdio_sync <= 2'b00;
    end else begin
      swclk_sync <= {swclk_sync[1:0], swclk_i};
      swdio_sync <= {swdio_sync[0], swdio_i};
    end
  end

  assign swclk_rise = (swclk_sync[2:1] == 2'b01);
  assign swclk_fall = (swclk_sync[2:1] == 2'b10);
  assign swdio_s    = swdio_sync[1];

  // line reset detect, 50 or more consecutive high bits at any point
  //
  // armed gates start bit detection. a line reset is a long run of ones, and
  // every one of those looks like a start bit, so without this the framer keeps
  // restarting inside the reset and is mid packet when the real one arrives.
  // only a low bit re-arms, which is exactly the idle period a host must send
  // after a reset before its first packet
  reg [6:0] reset_cnt;
  reg       armed;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reset_cnt  <= 7'd0;
      line_reset <= 1'b0;
      armed      <= 1'b1;
    end else begin
      line_reset <= 1'b0;
      if (swclk_rise) begin
        if (swdio_s) begin
          if (reset_cnt < RESET_CYCLES[6:0]) begin
            reset_cnt <= reset_cnt + 7'd1;
          end
          if (reset_cnt == RESET_CYCLES[6:0] - 7'd1) begin
            line_reset <= 1'b1;
            armed      <= 1'b0;
          end
        end else begin
          reset_cnt <= 7'd0;
          armed     <= 1'b1;
        end
      end
    end
  end

  reg [7:0]  req_sr;
  reg [32:0] data_sr;
  reg [5:0]  bitcnt;
  reg [2:0]  ack_r;
  reg        rnw_r;

  // even parity over the four request address/direction bits
  wire req_parity_ok = (^req_sr[4:1]) == req_sr[5];
  wire req_frame_ok  = req_sr[0] && !req_sr[6] && req_sr[7];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= ST_IDLE;
      swdio_o      <= 1'b0;
      swdio_oe     <= 1'b0;
      req_valid    <= 1'b0;
      req_apndp    <= 1'b0;
      req_rnw      <= 1'b0;
      req_addr     <= 2'b00;
      wr_valid     <= 1'b0;
      wr_parity_ok <= 1'b0;
      wr_data      <= 32'd0;
      req_sr       <= 8'd0;
      data_sr      <= 33'd0;
      bitcnt       <= 6'd0;
      ack_r        <= 3'd0;
      rnw_r        <= 1'b0;
    end else begin
      req_valid <= 1'b0;
      wr_valid  <= 1'b0;

      // a line reset aborts whatever is in flight and releases the bus
      if (line_reset) begin
        state    <= ST_IDLE;
        swdio_oe <= 1'b0;
        bitcnt   <= 6'd0;
      end else if (state == ST_REQ_CHK) begin
        // one clk after the last request bit, no swclk edge falls here at 4x or
        // better oversampling. this leaves the dp a full swclk period to answer
        if (req_frame_ok && req_parity_ok) begin
          req_valid <= 1'b1;
          req_apndp <= req_sr[1];
          req_rnw   <= req_sr[2];
          req_addr  <= {req_sr[4], req_sr[3]};
          rnw_r     <= req_sr[2];
          state     <= ST_TRN_A;
        end else begin
          // malformed packet, ignore it and wait for the host to resynchronise
          state <= ST_IDLE;
        end
      end else if (state == ST_WDONE) begin
        wr_valid     <= 1'b1;
        wr_data      <= data_sr[31:0];
        wr_parity_ok <= (^data_sr[31:0]) == data_sr[32];
        state        <= ST_IDLE;
      end else if (swclk_rise) begin
        case (state)
          // host idles low, a high bit is the packet start
          ST_IDLE: begin
            if (swdio_s && armed) begin
              req_sr <= {swdio_s, 7'd0};
              bitcnt <= 6'd1;
              state  <= ST_REQ;
            end
          end

          // request is sent lsb first, shift down and fill from the top so the
          // register ends up holding start in bit 0 and park in bit 7
          ST_REQ: begin
            req_sr <= {swdio_s, req_sr[7:1]};
            bitcnt <= bitcnt + 6'd1;
            if (bitcnt == 6'd7) begin
              state <= ST_REQ_CHK;
            end
          end

          // the trailing turnaround clock belongs to this transaction. nobody
          // drives it, so the pull up makes it read as a one. without consuming
          // it here the framer would mistake it for the next packet's start bit
          ST_TRN_END: begin
            state <= ST_IDLE;
          end

          // r13, the single turnaround clock before the host drives write data
          ST_WSKIP: begin
            bitcnt <= 6'd0;
            state  <= ST_WDATA;
          end

          // r14..r46
          ST_WDATA: begin
            data_sr <= {swdio_s, data_sr[32:1]};
            bitcnt  <= bitcnt + 6'd1;
            if (bitcnt == 6'd32) begin
              state <= ST_WDONE;
            end
          end

          default: begin
          end
        endcase
      end else if (swclk_fall) begin
        case (state)
          // f8, the turnaround. latch what the dp produced from req_valid
          ST_TRN_A: begin
            ack_r   <= rsp_ack;
            data_sr <= {^rsp_rdata, rsp_rdata};
            bitcnt  <= 6'd0;
            state   <= ST_ACK;
          end

          // f9..f11, drive the three ack bits lsb first
          ST_ACK: begin
            swdio_oe <= 1'b1;
            swdio_o  <= ack_r[bitcnt[1:0]];
            bitcnt   <= bitcnt + 6'd1;
            if (bitcnt == 6'd2) begin
              bitcnt <= 6'd0;
              if (ack_r != ACK_OK) begin
                state <= ST_NAK_REL;
              end else if (rnw_r) begin
                state <= ST_RDATA;
              end else begin
                state <= ST_WREL;
              end
            end
          end

          // f12..f44, keep driving straight into the data phase, no turnaround
          // between ack and read data because the target owns the bus for both
          ST_RDATA: begin
            swdio_oe <= 1'b1;
            swdio_o  <= data_sr[0];
            data_sr  <= {1'b0, data_sr[32:1]};
            bitcnt   <= bitcnt + 6'd1;
            if (bitcnt == 6'd32) begin
              state <= ST_RTRN;
            end
          end

          // f45, release after the host has sampled the parity bit
          ST_RTRN: begin
            swdio_oe <= 1'b0;
            state    <= ST_TRN_END;
          end

          // f12, release so the host can drive the write data
          ST_WREL: begin
            swdio_oe <= 1'b0;
            state    <= ST_WSKIP;
          end

          // a wait or fault has no data phase, but the turnaround after the ack
          // still has to be swallowed the same way
          ST_NAK_REL: begin
            swdio_oe <= 1'b0;
            state    <= ST_TRN_END;
          end

          default: begin
          end
        endcase
      end
    end
  end

endmodule

`default_nettype wire

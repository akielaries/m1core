`default_nettype none

// apb i2c single master, byte at a time
//
//   0x00 CTRL       [0] EN  [1] IRQEN
//   0x04 CMD        writing starts an operation, bits combine in this order:
//                   [0] START  [2] WRITE  [3] READ  [1] STOP
//                   [4] ACK, the bit sent after a READ, 1 acks and 0 nacks
//   0x08 DATA       byte to send on WRITE, byte received after READ
//   0x0c STATUS     [0] BUSY  [1] RXACK, 1 means the slave did not ack
//   0x10 CLKDIV     scl quarter period in pclk cycles, minus one
//   0x14 INTSTATUS  read pending, write one to clear
//
// one CMD write can do start, a byte, and stop, which is the whole of a short
// register access. the alternative, one register write per bus event, spends
// more apb traffic on sequencing than on data.
//
// scl and sda are open drain: the pin is driven low or released, never driven
// high, so a slave can hold either line down. releasing scl and waiting for it
// to actually rise is clock stretching, and is honoured here.

module apb_i2c (
  input  wire        clk,
  input  wire        rst_n,

  // apb slave
  input  wire        psel,
  input  wire        penable,
  input  wire        pwrite,
  input  wire [31:0] paddr,
  input  wire [31:0] pwdata,
  output reg  [31:0] prdata,
  output wire        pready,

  output wire        irq,

  inout  wire        scl,
  inout  wire        sda
);

  localparam [2:0] REG_CTRL      = 3'd0;   // 0x00
  localparam [2:0] REG_CMD       = 3'd1;   // 0x04
  localparam [2:0] REG_DATA      = 3'd2;   // 0x08
  localparam [2:0] REG_STATUS    = 3'd3;   // 0x0c
  localparam [2:0] REG_CLKDIV    = 3'd4;   // 0x10
  localparam [2:0] REG_INTSTATUS = 3'd5;   // 0x14

  localparam [2:0] ST_IDLE   = 3'd0;
  localparam [2:0] ST_START  = 3'd1;
  localparam [2:0] ST_WR     = 3'd2;
  localparam [2:0] ST_WR_ACK = 3'd3;
  localparam [2:0] ST_RD     = 3'd4;
  localparam [2:0] ST_RD_ACK = 3'd5;
  localparam [2:0] ST_STOP   = 3'd6;

  assign pready = 1'b1;

  wire [2:0] reg_sel = paddr[4:2];
  wire       wr      = psel && penable && pwrite;

  reg [1:0]  ctrl;
  reg [15:0] clkdiv;
  reg [7:0]  shift;
  reg [7:0]  txbyte;
  reg [2:0]  state;
  reg [1:0]  q;
  reg [3:0]  bitcnt;
  reg [15:0] divcnt;
  reg        scl_oe;
  reg        sda_oe;
  reg        rxack;
  reg        irq_pending;

  // what the pending command still has left to do
  reg        do_wr;
  reg        do_rd;
  reg        do_stop;
  reg        ack_val;

  wire ctrl_en    = ctrl[0];
  wire ctrl_irqen = ctrl[1];

  wire busy = (state != ST_IDLE);

  assign irq = irq_pending && ctrl_irqen;

  // open drain: drive low or let the pull up take it high
  assign scl = scl_oe ? 1'b0 : 1'bz;
  assign sda = sda_oe ? 1'b0 : 1'bz;

  wire scl_i = scl;
  wire sda_i = sda;

  // a quarter of an scl period. the last quarter of a phase that released scl
  // waits for the line to actually be high, which is clock stretching
  wire qdone   = (divcnt >= clkdiv);
  wire stretch = (q == 2'd1) && !scl_oe && !scl_i;
  wire qtick   = busy && qdone && !stretch;

  wire cmd_start = pwdata[0];
  wire cmd_stop  = pwdata[1];
  wire cmd_wr    = pwdata[2];
  wire cmd_rd    = pwdata[3];
  wire cmd_ack   = pwdata[4];

  // where to go once the current phase finishes
  wire [2:0] next_after =
      do_wr   ? ST_WR   :
      do_rd   ? ST_RD   :
      do_stop ? ST_STOP : ST_IDLE;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl        <= 2'd0;
      clkdiv      <= 16'd0;
      shift       <= 8'd0;
      txbyte      <= 8'd0;
      state       <= ST_IDLE;
      q           <= 2'd0;
      bitcnt      <= 4'd0;
      divcnt      <= 16'd0;
      scl_oe      <= 1'b0;
      sda_oe      <= 1'b0;
      rxack       <= 1'b0;
      irq_pending <= 1'b0;
      do_wr       <= 1'b0;
      do_rd       <= 1'b0;
      do_stop     <= 1'b0;
      ack_val     <= 1'b0;
    end else begin
      if (busy) begin
        if (qtick) begin
          divcnt <= 16'd0;
          q      <= q + 2'd1;

          case (state)
            // sda falls while scl is high
            ST_START: begin
              case (q)
                2'd0: begin scl_oe <= 1'b0; sda_oe <= 1'b0; end
                2'd1: sda_oe <= 1'b1;
                2'd2: scl_oe <= 1'b1;
                default: begin
                  state  <= next_after;
                  bitcnt <= 4'd0;
                  if (do_wr) begin
                    do_wr <= 1'b0;
                  end else if (do_rd) begin
                    do_rd <= 1'b0;
                  end
                end
              endcase
            end

            // sda is set while scl is low, and held across the high period
            ST_WR: begin
              case (q)
                2'd0: sda_oe <= ~txbyte[7];
                2'd1: scl_oe <= 1'b0;
                2'd2: ;
                default: begin
                  scl_oe <= 1'b1;
                  txbyte <= {txbyte[6:0], 1'b0};
                  if (bitcnt == 4'd7) begin
                    state  <= ST_WR_ACK;
                    bitcnt <= 4'd0;
                  end else begin
                    bitcnt <= bitcnt + 4'd1;
                  end
                end
              endcase
            end

            // release sda and read what the slave does with it
            ST_WR_ACK: begin
              case (q)
                2'd0: sda_oe <= 1'b0;
                2'd1: scl_oe <= 1'b0;
                2'd2: rxack <= sda_i;
                default: begin
                  scl_oe <= 1'b1;
                  state  <= do_rd ? ST_RD : (do_stop ? ST_STOP : ST_IDLE);
                  do_rd  <= 1'b0;
                  bitcnt <= 4'd0;
                end
              endcase
            end

            ST_RD: begin
              case (q)
                2'd0: sda_oe <= 1'b0;
                2'd1: scl_oe <= 1'b0;
                2'd2: shift <= {shift[6:0], sda_i};
                default: begin
                  scl_oe <= 1'b1;
                  if (bitcnt == 4'd7) begin
                    state  <= ST_RD_ACK;
                    bitcnt <= 4'd0;
                  end else begin
                    bitcnt <= bitcnt + 4'd1;
                  end
                end
              endcase
            end

            // drive the ack the command asked for
            ST_RD_ACK: begin
              case (q)
                2'd0: sda_oe <= ack_val;
                2'd1: scl_oe <= 1'b0;
                2'd2: ;
                default: begin
                  scl_oe <= 1'b1;
                  state  <= do_stop ? ST_STOP : ST_IDLE;
                end
              endcase
            end

            // sda rises while scl is high
            ST_STOP: begin
              case (q)
                2'd0: sda_oe <= 1'b1;
                2'd1: scl_oe <= 1'b0;
                2'd2: sda_oe <= 1'b0;
                default: begin
                  state   <= ST_IDLE;
                  do_stop <= 1'b0;
                end
              endcase
            end

            default: state <= ST_IDLE;
          endcase

          // finishing the whole command is what raises the interrupt
          if (state != ST_IDLE && q == 2'd3) begin
            if ((state == ST_STOP) ||
                (state == ST_WR_ACK && !do_rd && !do_stop) ||
                (state == ST_RD_ACK && !do_stop)) begin
              irq_pending <= 1'b1;
            end
          end
        end else begin
          divcnt <= divcnt + 16'd1;
        end
      end

      if (wr) begin
        case (reg_sel)
          REG_CTRL:   ctrl   <= pwdata[1:0];
          REG_CLKDIV: clkdiv <= pwdata[15:0];
          REG_DATA:   txbyte <= pwdata[7:0];
          REG_CMD: if (ctrl_en && !busy) begin
            do_wr   <= cmd_wr;
            do_rd   <= cmd_rd;
            do_stop <= cmd_stop;
            ack_val <= cmd_ack;
            q       <= 2'd0;
            divcnt  <= 16'd0;
            bitcnt  <= 4'd0;
            if (cmd_start) begin
              state <= ST_START;
            end else if (cmd_wr) begin
              state <= ST_WR;
              do_wr <= 1'b0;
            end else if (cmd_rd) begin
              state <= ST_RD;
              do_rd <= 1'b0;
            end else if (cmd_stop) begin
              state <= ST_STOP;
            end
          end
          // write one to clear
          REG_INTSTATUS: if (pwdata[0]) irq_pending <= 1'b0;
          default: ;
        endcase
      end
    end
  end

  always @(*) begin
    case (reg_sel)
      REG_CTRL:      prdata = {30'd0, ctrl};
      REG_DATA:      prdata = {24'd0, shift};
      REG_STATUS:    prdata = {30'd0, rxack, busy};
      REG_CLKDIV:    prdata = {16'd0, clkdiv};
      REG_INTSTATUS: prdata = {31'd0, irq_pending};
      default:       prdata = 32'd0;
    endcase
  end

endmodule

`default_nettype wire

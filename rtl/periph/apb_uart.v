`default_nettype none

// apb uart, register compatible with the arm cmsdk uart
//
// gowin's empu m1 uses the cmsdk peripherals, so matching this layout means the
// GOWIN_M1_uart.c driver in m1kern's bsp drives this block unchanged, as does
// anything written against an mps2. same trick as the coresight id contract
//
//   0x00 DATA       write: tx byte, read: rx byte (reading clears RXBF)
//   0x04 STATE      [0] TXBF  [1] RXBF  [2] TXOR  [3] RXOR, write 1 to clear OR
//   0x08 CTRL       [0] TXEN  [1] RXEN  [2] TXIRQEN [3] RXIRQEN
//                   [4] TXORIRQEN [5] RXORIRQEN [6] HSTM
//   0x0c INTSTATUS  read: pending irqs, write 1 to clear
//   0x10 BAUDDIV    system clocks per bit, minimum 16
//
// 8 data bits, no parity, one stop bit. single byte buffers each way, which is
// what the cmsdk block does

module apb_uart (
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

  // serial
  input  wire        rxd,
  output wire        txd,

  output wire        irq
);

  // decoded as a word index, not a byte offset. masking the byte address with
  // 0xf aliases BAUDDIV at 0x10 onto DATA at 0x00
  localparam [2:0] REG_DATA      = 3'd0;   // 0x00
  localparam [2:0] REG_STATE     = 3'd1;   // 0x04
  localparam [2:0] REG_CTRL      = 3'd2;   // 0x08
  localparam [2:0] REG_INTSTATUS = 3'd3;   // 0x0c
  localparam [2:0] REG_BAUDDIV   = 3'd4;   // 0x10

  // no wait states, the register file answers immediately
  assign pready = 1'b1;

  wire [2:0] reg_sel = paddr[4:2];
  wire       wr      = psel && penable && pwrite;
  wire       rd      = psel && penable && !pwrite;

  reg [6:0]  ctrl;
  reg [15:0] bauddiv;

  reg [7:0]  tx_buf;
  reg        tx_full;
  reg [7:0]  rx_buf;
  reg        rx_full;
  reg        tx_overrun, rx_overrun;

  reg        irq_tx, irq_rx, irq_txor, irq_rxor;

  wire ctrl_txen      = ctrl[0];
  wire ctrl_rxen      = ctrl[1];
  wire ctrl_txirqen   = ctrl[2];
  wire ctrl_rxirqen   = ctrl[3];
  wire ctrl_txorirqen = ctrl[4];
  wire ctrl_rxorirqen = ctrl[5];

  assign irq = (irq_tx   && ctrl_txirqen)   || (irq_rx   && ctrl_rxirqen) ||
               (irq_txor && ctrl_txorirqen) || (irq_rxor && ctrl_rxorirqen);

  // ---------------------------------------------------------------------------
  // transmit
  // ---------------------------------------------------------------------------
  reg [9:0]  tx_shift;      // stop bit, 8 data, start bit
  reg [3:0]  tx_bits;
  reg [15:0] tx_div;
  reg        tx_busy;

  assign txd = tx_busy ? tx_shift[0] : 1'b1;

  wire tx_load = wr && (reg_sel == REG_DATA) && ctrl_txen;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_shift <= 10'h3ff;
      tx_bits  <= 4'd0;
      tx_div   <= 16'd0;
      tx_busy  <= 1'b0;
      tx_buf   <= 8'd0;
      tx_full  <= 1'b0;
    end else begin
      if (tx_load) begin
        if (tx_full || tx_busy) begin
          // writing while the buffer is occupied loses the byte, which the
          // overrun flag exists to report
        end else begin
          tx_buf  <= pwdata[7:0];
          tx_full <= 1'b1;
        end
      end

      if (!tx_busy) begin
        if (tx_full) begin
          tx_shift <= {1'b1, tx_buf, 1'b0};   // stop, data, start
          tx_bits  <= 4'd10;
          tx_div   <= bauddiv;
          tx_busy  <= 1'b1;
          tx_full  <= 1'b0;
        end
      end else begin
        if (tx_div > 16'd1) begin
          tx_div <= tx_div - 16'd1;
        end else begin
          tx_div   <= bauddiv;
          tx_shift <= {1'b1, tx_shift[9:1]};
          tx_bits  <= tx_bits - 4'd1;
          if (tx_bits == 4'd1) begin
            tx_busy <= 1'b0;
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // receive, sampled at the middle of each bit
  // ---------------------------------------------------------------------------
  reg [2:0]  rxd_sync;
  reg [9:0]  rx_shift;
  reg [3:0]  rx_bits;
  reg [15:0] rx_div;
  reg        rx_busy;

  wire rxd_s = rxd_sync[2];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxd_sync <= 3'b111;
      rx_shift <= 10'd0;
      rx_bits  <= 4'd0;
      rx_div   <= 16'd0;
      rx_busy  <= 1'b0;
    end else begin
      rxd_sync <= {rxd_sync[1:0], rxd};

      if (!rx_busy) begin
        // start bit: a falling edge on an idle line. wait half a bit so every
        // later sample lands mid bit
        if (ctrl_rxen && rxd_sync[2] && !rxd_sync[1]) begin
          rx_busy <= 1'b1;
          rx_bits <= 4'd9;
          rx_div  <= {1'b0, bauddiv[15:1]};
        end
      end else begin
        if (rx_div > 16'd1) begin
          rx_div <= rx_div - 16'd1;
        end else begin
          rx_div   <= bauddiv;
          rx_shift <= {rxd_s, rx_shift[9:1]};
          rx_bits  <= rx_bits - 4'd1;
          if (rx_bits == 4'd1) begin
            rx_busy <= 1'b0;
          end
        end
      end
    end
  end

  // rx_done fires on the same edge as the final shift, so rx_shift still holds
  // its pre-shift value here. the completed byte is therefore the current
  // sample concatenated with the top of the shift register, not rx_shift[9:2].
  // getting this wrong shifts the whole byte left by one and folds the start
  // bit into bit 0
  wire rx_done = rx_busy && (rx_div <= 16'd1) && (rx_bits == 4'd1);
  wire [7:0] rx_byte = {rxd_s, rx_shift[9:3]};

  // ---------------------------------------------------------------------------
  // register file
  // ---------------------------------------------------------------------------
  wire [31:0] state_value = {28'd0, rx_overrun, tx_overrun, rx_full, tx_full || tx_busy};

  always @(*) begin
    case (reg_sel)
      REG_DATA:      prdata = {24'd0, rx_buf};
      REG_STATE:     prdata = state_value;
      REG_CTRL:      prdata = {25'd0, ctrl};
      REG_INTSTATUS: prdata = {28'd0, irq_rxor, irq_txor, irq_rx, irq_tx};
      REG_BAUDDIV:   prdata = {16'd0, bauddiv};
      default:       prdata = 32'd0;
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl       <= 7'd0;
      bauddiv    <= 16'd16;
      rx_buf     <= 8'd0;
      rx_full    <= 1'b0;
      tx_overrun <= 1'b0;
      rx_overrun <= 1'b0;
      irq_tx     <= 1'b0;
      irq_rx     <= 1'b0;
      irq_txor   <= 1'b0;
      irq_rxor   <= 1'b0;
    end else begin
      // a completed transmit frees the buffer
      if (tx_busy && (tx_div <= 16'd1) && (tx_bits == 4'd1)) begin
        irq_tx <= 1'b1;
      end

      if (rx_done) begin
        if (rx_full) begin
          rx_overrun <= 1'b1;
          irq_rxor   <= 1'b1;
        end else begin
          rx_buf  <= rx_byte;
          rx_full <= 1'b1;
          irq_rx  <= 1'b1;
        end
      end

      if (tx_load && (tx_full || tx_busy)) begin
        tx_overrun <= 1'b1;
        irq_txor   <= 1'b1;
      end

      if (rd && reg_sel == REG_DATA) begin
        rx_full <= 1'b0;
      end

      if (wr) begin
        case (reg_sel)
          REG_CTRL: ctrl <= pwdata[6:0];
          // write one to clear the overrun flags
          REG_STATE: begin
            if (pwdata[2]) tx_overrun <= 1'b0;
            if (pwdata[3]) rx_overrun <= 1'b0;
          end
          REG_INTSTATUS: begin
            if (pwdata[0]) irq_tx   <= 1'b0;
            if (pwdata[1]) irq_rx   <= 1'b0;
            if (pwdata[2]) irq_txor <= 1'b0;
            if (pwdata[3]) irq_rxor <= 1'b0;
          end
          REG_BAUDDIV: bauddiv <= pwdata[15:0];
          default: begin
          end
        endcase
      end
    end
  end

endmodule

`default_nettype wire

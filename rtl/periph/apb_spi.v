`default_nettype none

// apb spi master, all four modes, eight bits per transfer
//
//   0x00 CTRL       [0] EN  [1] CPOL  [2] CPHA  [3] IRQEN
//   0x04 STATUS     [0] BUSY
//   0x08 DATA       write starts a transfer, read returns the byte shifted in
//   0x0c CLKDIV     sclk half period in pclk cycles, minus one
//   0x10 SSEL       bit n drives ssel_n[n] low while set
//   0x14 INTSTATUS  read pending, write one to clear
//
// msb first only. lsb first doubles every shift and sample case for a mode
// almost no device uses, so it is left out rather than left untested.
//
// the chip selects are driven directly rather than automatically around a
// transfer, because a real device usually needs one select held across several
// bytes and hardware that drops it every byte cannot express that

module apb_spi #(
  parameter SSEL_WIDTH = 1
) (
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

  output wire                  sclk,
  output wire                  mosi,
  input  wire                  miso,
  output wire [SSEL_WIDTH-1:0] ssel_n
);

  localparam [2:0] REG_CTRL      = 3'd0;   // 0x00
  localparam [2:0] REG_STATUS    = 3'd1;   // 0x04
  localparam [2:0] REG_DATA      = 3'd2;   // 0x08
  localparam [2:0] REG_CLKDIV    = 3'd3;   // 0x0c
  localparam [2:0] REG_SSEL      = 3'd4;   // 0x10
  localparam [2:0] REG_INTSTATUS = 3'd5;   // 0x14

  assign pready = 1'b1;

  wire [2:0] reg_sel = paddr[4:2];
  wire       wr      = psel && penable && pwrite;

  reg [3:0]  ctrl;
  reg [15:0] clkdiv;
  reg [SSEL_WIDTH-1:0] ssel;
  reg [7:0]  shift;
  reg        rx_bit;
  reg [4:0]  edge_cnt;
  reg [15:0] divcnt;
  reg        busy;
  reg        sclk_r;
  reg        irq_pending;

  wire ctrl_en    = ctrl[0];
  wire ctrl_cpol  = ctrl[1];
  wire ctrl_cpha  = ctrl[2];
  wire ctrl_irqen = ctrl[3];

  assign irq    = irq_pending && ctrl_irqen;
  assign sclk   = sclk_r;
  assign mosi   = shift[7];
  assign ssel_n = ~ssel;

  wire start = wr && (reg_sel == REG_DATA) && ctrl_en && !busy;

  // one edge every clkdiv+1 cycles. sixteen edges is eight bits: the even ones
  // are leading, the odd ones trailing
  wire edge_now = busy && (divcnt >= clkdiv);
  wire leading  = (edge_cnt[0] == 1'b0);
  wire last     = (edge_cnt == 5'd15);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl        <= 4'd0;
      clkdiv      <= 16'd0;
      ssel        <= {SSEL_WIDTH{1'b0}};
      shift       <= 8'd0;
      rx_bit      <= 1'b0;
      edge_cnt    <= 5'd0;
      divcnt      <= 16'd0;
      busy        <= 1'b0;
      sclk_r      <= 1'b0;
      irq_pending <= 1'b0;
    end else begin
      if (start) begin
        shift    <= pwdata[7:0];
        busy     <= 1'b1;
        edge_cnt <= 5'd0;
        divcnt   <= 16'd0;
        // idle level is cpol, and with cpha 0 the first data bit has to be on
        // the wire before the first edge. mosi is shift[7], so loading the
        // shift register here is what satisfies that
        sclk_r   <= ctrl_cpol;
      end else if (busy) begin
        if (edge_now) begin
          divcnt   <= 16'd0;
          sclk_r   <= ~sclk_r;
          edge_cnt <= edge_cnt + 5'd1;

          if (!ctrl_cpha) begin
            // mode 0/2: sample on the leading edge, move on the trailing one
            if (leading) begin
              rx_bit <= miso;
            end else begin
              shift <= {shift[6:0], rx_bit};
            end
          end else begin
            // mode 1/3: the other way round. the first leading edge must not
            // shift, because the bit it would shift out is already on the wire
            if (!leading) begin
              if (last) begin
                shift <= {shift[6:0], miso};
              end else begin
                rx_bit <= miso;
              end
            end else if (edge_cnt != 5'd0) begin
              shift <= {shift[6:0], rx_bit};
            end
          end

          if (last) begin
            busy        <= 1'b0;
            irq_pending <= 1'b1;
          end
        end else begin
          divcnt <= divcnt + 16'd1;
        end
      end

      if (wr) begin
        case (reg_sel)
          REG_CTRL:   ctrl   <= pwdata[3:0];
          REG_CLKDIV: clkdiv <= pwdata[15:0];
          REG_SSEL:   ssel   <= pwdata[SSEL_WIDTH-1:0];
          // write one to clear
          REG_INTSTATUS: if (pwdata[0]) irq_pending <= 1'b0;
          default: ;
        endcase
      end
    end
  end

  always @(*) begin
    case (reg_sel)
      REG_CTRL:      prdata = {28'd0, ctrl};
      REG_STATUS:    prdata = {31'd0, busy};
      REG_DATA:      prdata = {24'd0, shift};
      REG_CLKDIV:    prdata = {16'd0, clkdiv};
      REG_SSEL:      prdata = {{(32 - SSEL_WIDTH){1'b0}}, ssel};
      REG_INTSTATUS: prdata = {31'd0, irq_pending};
      default:       prdata = 32'd0;
    endcase
  end

endmodule

`default_nettype wire

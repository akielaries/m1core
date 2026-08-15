`default_nettype none

// apb real time counter
//
// a prescaler dividing pclk down to a tick, a counter of those ticks, and a
// match register that raises an interrupt when the counter reaches it
//
//   0x00 CTRL       [0] EN  [1] IRQEN
//   0x04 COUNT      tick counter, writable so software can set the time
//   0x08 MATCH      interrupt when COUNT reaches this value
//   0x0c INTSTATUS  read pending, write one to clear
//   0x10 PRESCALE   pclk cycles per tick, minus one
//
// PRESCALE resets to zero, which ticks once per pclk. that is deliberate: the
// hardware has no way to discover the fabric clock, so software programs it.
// the generated header carries SYSTEM_CLOCK_HZ for exactly this, and writing
// SYSTEM_CLOCK_HZ - 1 gives a one second tick

module apb_rtc (
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

  output wire        irq
);

  localparam [2:0] REG_CTRL      = 3'd0;   // 0x00
  localparam [2:0] REG_COUNT     = 3'd1;   // 0x04
  localparam [2:0] REG_MATCH     = 3'd2;   // 0x08
  localparam [2:0] REG_INTSTATUS = 3'd3;   // 0x0c
  localparam [2:0] REG_PRESCALE  = 3'd4;   // 0x10

  assign pready = 1'b1;

  wire [2:0] reg_sel = paddr[4:2];
  wire       wr      = psel && penable && pwrite;

  reg [1:0]  ctrl;
  reg [31:0] count;
  reg [31:0] match;
  reg [31:0] prescale;
  reg [31:0] divcnt;
  reg        irq_pending;

  wire ctrl_en    = ctrl[0];
  wire ctrl_irqen = ctrl[1];

  assign irq = irq_pending && ctrl_irqen;

  // >= rather than ==, so lowering PRESCALE below a divider already past it
  // still ticks instead of counting all the way round
  wire tick = ctrl_en && (divcnt >= prescale);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl        <= 2'd0;
      count       <= 32'd0;
      match       <= 32'd0;
      prescale    <= 32'd0;
      divcnt      <= 32'd0;
      irq_pending <= 1'b0;
    end else begin
      if (ctrl_en) begin
        if (tick) begin
          divcnt <= 32'd0;
          count  <= count + 32'd1;
          // compared against the value the counter is about to take, so a
          // match one tick ahead fires on that tick rather than one late
          if ((count + 32'd1) == match) begin
            irq_pending <= 1'b1;
          end
        end else begin
          divcnt <= divcnt + 32'd1;
        end
      end

      if (wr) begin
        case (reg_sel)
          REG_CTRL: ctrl <= pwdata[1:0];
          REG_COUNT: begin
            count  <= pwdata;
            // restart the prescaler too, or setting the time leaves a partial
            // tick in flight and the first interval is short
            divcnt <= 32'd0;
          end
          REG_MATCH: match <= pwdata;
          REG_PRESCALE: begin
            prescale <= pwdata;
            divcnt   <= 32'd0;
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
      REG_COUNT:     prdata = count;
      REG_MATCH:     prdata = match;
      REG_INTSTATUS: prdata = {31'd0, irq_pending};
      REG_PRESCALE:  prdata = prescale;
      default:       prdata = 32'd0;
    endcase
  end

endmodule

`default_nettype wire

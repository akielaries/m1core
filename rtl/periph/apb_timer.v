`default_nettype none

// apb timer, register compatible with the arm cmsdk timer
//
// same layout gowin's empu m1 exposes, so a driver written against either works
// unchanged:
//
//   0x00 CTRL       [0] EN  [1] SELEXTEN  [2] SELEXTCLK  [3] IRQEN
//   0x04 VALUE      current value, counts down
//   0x08 RELOAD     value loaded when it wraps
//   0x0c INTSTATUS  read: [0] pending, write one to clear
//
// the external enable and external clock inputs the cmsdk block supports are
// not wired: there is no external timer pin on this mcu, so SELEXTEN and
// SELEXTCLK read back as written and otherwise do nothing

module apb_timer (
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

  localparam [1:0] REG_CTRL      = 2'd0;   // 0x00
  localparam [1:0] REG_VALUE     = 2'd1;   // 0x04
  localparam [1:0] REG_RELOAD    = 2'd2;   // 0x08
  localparam [1:0] REG_INTSTATUS = 2'd3;   // 0x0c

  assign pready = 1'b1;

  wire [1:0] reg_sel = paddr[3:2];
  wire       wr      = psel && penable && pwrite;

  reg [3:0]  ctrl;
  reg [31:0] value;
  reg [31:0] reload;
  reg        irq_pending;

  wire ctrl_en    = ctrl[0];
  wire ctrl_irqen = ctrl[3];

  assign irq = irq_pending && ctrl_irqen;

  // the counter wraps when it reaches zero, reloading and raising the interrupt
  wire wrap = ctrl_en && (value == 32'd0);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl        <= 4'd0;
      value       <= 32'd0;
      reload      <= 32'd0;
      irq_pending <= 1'b0;
    end else begin
      if (ctrl_en) begin
        if (wrap) begin
          value       <= reload;
          irq_pending <= 1'b1;
        end else begin
          value <= value - 32'd1;
        end
      end

      if (wr) begin
        case (reg_sel)
          REG_CTRL:   ctrl   <= pwdata[3:0];
          REG_VALUE:  value  <= pwdata;
          REG_RELOAD: begin
            reload <= pwdata;
            // writing reload while stopped also primes the counter, otherwise
            // the first period runs from whatever value happened to be left
            if (!ctrl_en) begin
              value <= pwdata;
            end
          end
          // write one to clear
          default: if (pwdata[0]) irq_pending <= 1'b0;
        endcase
      end
    end
  end

  always @(*) begin
    case (reg_sel)
      REG_CTRL:   prdata = {28'd0, ctrl};
      REG_VALUE:  prdata = value;
      REG_RELOAD: prdata = reload;
      default:    prdata = {31'd0, irq_pending};
    endcase
  end

endmodule

`default_nettype wire

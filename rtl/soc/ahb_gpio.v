`default_nettype none

// ahb-lite gpio
//
//   +0x00 data  rw, current output value
//   +0x04 dir   rw, 1 = drive the pin, kept for firmware realism
//   +0x08 set   wo, write ones to set those bits
//   +0x0c clr   wo, write ones to clear those bits
//
// set/clr exist so firmware never has to read-modify-write, and so a debugger
// can toggle a single pin with one memory write

module ahb_gpio #(
  parameter WIDTH = 2
) (
  input  wire        clk,
  input  wire        rst_n,

  input  wire        hsel,
  input  wire [31:0] haddr,
  input  wire        hwrite,
  input  wire [1:0]  htrans,
  input  wire        hready,
  input  wire [31:0] hwdata,
  output reg  [31:0] hrdata,
  output wire [WIDTH-1:0]gpio_o
);

  reg [WIDTH-1:0] data_r;
  reg [WIDTH-1:0] dir_r;

  reg [3:0] a_off;
  reg       a_write;
  reg       a_valid;

  wire addr_phase = hsel && hready && htrans[1];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_off   <= 4'd0;
      a_write <= 1'b0;
      a_valid <= 1'b0;
    end else begin
      a_valid <= addr_phase;
      if (addr_phase) begin
        a_off   <= haddr[3:0];
        a_write <= hwrite;
      end
    end
  end

  always @(*) begin
    case (a_off[3:2])
      2'd0:    hrdata = {{(32-WIDTH){1'b0}}, data_r};
      2'd1:    hrdata = {{(32-WIDTH){1'b0}}, dir_r};
      default: hrdata = 32'd0;
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_r <= {WIDTH{1'b0}};
      dir_r  <= {WIDTH{1'b1}};
    end else if (a_valid && a_write) begin
      case (a_off[3:2])
        2'd0: data_r <= hwdata[WIDTH-1:0];
        2'd1: dir_r  <= hwdata[WIDTH-1:0];
        2'd2: data_r <= data_r | hwdata[WIDTH-1:0];
        2'd3: data_r <= data_r & ~hwdata[WIDTH-1:0];
        default: begin
        end
      endcase
    end
  end

  assign gpio_o = data_r & dir_r;

endmodule

`default_nettype wire

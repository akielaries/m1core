`default_nettype none

// ahb-lite address decode and read data mux
//
// memory map:
//   0x00000000  itcm, code. gdb load lands here
//   0x20000000  dtcm, data
//   0x40000000  ahb1 peripherals, gpio
//   0x50000000  apb1 peripherals, behind the bridge
//   0xe0000000  ppb, rom table and scs
//
// the slave select must be registered as well as decoded, because hrdata comes
// back one cycle after the address phase that chose the slave

module ahb_fabric (
  input  wire        clk,
  input  wire        rst_n,

  // from the master
  input  wire [31:0] haddr,
  input  wire [1:0]  htrans,
  output reg  [31:0] hrdata,
  output reg         hready,
  output wire        hresp,

  // slave selects
  output wire        hsel_itcm,
  output wire        hsel_dtcm,
  output wire        hsel_gpio,
  output wire        hsel_apb,
  output wire        hsel_ppb,
  input  wire [31:0] hrdata_itcm,
  input  wire [31:0] hrdata_dtcm,
  input  wire [31:0] hrdata_gpio,
  input  wire [31:0] hrdata_apb,
  input  wire [31:0] hrdata_ppb,

  // per slave ready. zero wait state slaves tie these high; a bridge to a
  // slower bus drives its own low while a transfer is in flight
  input  wire        hreadyout_itcm,
  input  wire        hreadyout_dtcm,
  input  wire        hreadyout_gpio,
  input  wire        hreadyout_apb,
  input  wire        hreadyout_ppb
);

  localparam [2:0] SEL_NONE = 3'd0;
  localparam [2:0] SEL_ITCM = 3'd1;
  localparam [2:0] SEL_DTCM = 3'd2;
  localparam [2:0] SEL_GPIO = 3'd3;
  localparam [2:0] SEL_PPB  = 3'd4;
  localparam [2:0] SEL_APB  = 3'd5;

  assign hresp = 1'b0;

  wire in_itcm = (haddr[31:28] == 4'h0);
  wire in_dtcm = (haddr[31:28] == 4'h2);
  wire in_gpio = (haddr[31:28] == 4'h4);
  wire in_apb  = (haddr[31:28] == 4'h5);
  wire in_ppb  = (haddr[31:20] == 12'he00);

  assign hsel_itcm = in_itcm;
  assign hsel_dtcm = in_dtcm;
  assign hsel_gpio = in_gpio;
  assign hsel_apb  = in_apb;
  assign hsel_ppb  = in_ppb;

  reg [2:0] sel_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sel_q <= SEL_NONE;
    end else if (htrans[1]) begin
      if (in_itcm) begin
        sel_q <= SEL_ITCM;
      end else if (in_dtcm) begin
        sel_q <= SEL_DTCM;
      end else if (in_gpio) begin
        sel_q <= SEL_GPIO;
      end else if (in_apb) begin
        sel_q <= SEL_APB;
      end else if (in_ppb) begin
        sel_q <= SEL_PPB;
      end else begin
        sel_q <= SEL_NONE;
      end
    end
  end

  // hready qualifies both phases and comes from whichever slave owns the
  // current data phase, which is the one selected during the address phase
  always @(*) begin
    case (sel_q)
      SEL_ITCM: hready = hreadyout_itcm;
      SEL_DTCM: hready = hreadyout_dtcm;
      SEL_GPIO: hready = hreadyout_gpio;
      SEL_APB:  hready = hreadyout_apb;
      SEL_PPB:  hready = hreadyout_ppb;
      default:  hready = 1'b1;
    endcase
  end

  always @(*) begin
    case (sel_q)
      SEL_ITCM: hrdata = hrdata_itcm;
      SEL_DTCM: hrdata = hrdata_dtcm;
      SEL_GPIO: hrdata = hrdata_gpio;
      SEL_APB:  hrdata = hrdata_apb;
      SEL_PPB:  hrdata = hrdata_ppb;
      // an unmapped read returns zero rather than an error, so a stray probe
      // access cannot set stickyerr and lock out every later transfer
      default:  hrdata = 32'd0;
    endcase
  end

endmodule

`default_nettype wire

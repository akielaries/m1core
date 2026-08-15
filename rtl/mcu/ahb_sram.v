`default_nettype none

// ahb-lite sram slave, zero wait states
//
// the read is started in the address phase so the synchronous memory presents
// its data in the data phase, which is exactly the ahb pipeline shape and needs
// no wait states. this is the memory gdb load writes into

module ahb_sram #(
  parameter WORDS     = 4096,
  parameter              INIT_FILE = ""
) (
  input  wire        clk,
  input  wire        rst_n,

  input  wire        hsel,
  input  wire [31:0] haddr,
  input  wire        hwrite,
  input  wire [2:0]  hsize,
  input  wire [1:0]  htrans,
  input  wire        hready,
  input  wire [31:0] hwdata,
  output reg  [31:0] hrdata
);

  localparam AW = $clog2(WORDS);

  reg [31:0] mem [0:WORDS-1];

  wire addr_phase = hsel && hready && htrans[1];

  reg [AW-1:0] a_word;
  reg          a_write;
  reg          a_valid;
  reg [2:0]    a_size;
  reg [1:0]    a_byte;

  wire [AW-1:0] word_index = haddr[AW+1:2];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_valid <= 1'b0;
      a_write <= 1'b0;
      a_word  <= {AW{1'b0}};
      a_size  <= 3'd2;
      a_byte  <= 2'd0;
    end else begin
      a_valid <= addr_phase;
      if (addr_phase) begin
        a_word  <= word_index;
        a_write <= hwrite;
        a_size  <= hsize;
        a_byte  <= haddr[1:0];
      end
    end
  end

  // byte lane enables for the captured access
  reg [3:0] wbe;

  always @(*) begin
    case (a_size)
      3'd0:    wbe = 4'b0001 << a_byte;
      3'd1:    wbe = a_byte[1] ? 4'b1100 : 4'b0011;
      default: wbe = 4'b1111;
    endcase
  end

  always @(posedge clk) begin
    // read is launched in the address phase, data lands in the data phase
    if (addr_phase && !hwrite) begin
      hrdata <= mem[word_index];
    end
    if (a_valid && a_write) begin
      if (wbe[0]) mem[a_word][7:0]   <= hwdata[7:0];
      if (wbe[1]) mem[a_word][15:8]  <= hwdata[15:8];
      if (wbe[2]) mem[a_word][23:16] <= hwdata[23:16];
      if (wbe[3]) mem[a_word][31:24] <= hwdata[31:24];
    end
  end

  // a generate guard rather than an if inside initial, which gowin's synthesiser
  // handles far more reliably for bram preload
  generate
    if (INIT_FILE != "") begin : g_init
      initial begin
        $readmemh(INIT_FILE, mem);
      end
    end
  endgenerate

endmodule

`default_nettype wire

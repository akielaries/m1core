`timescale 1ns/1ps
`default_nettype none

// ahb expansion window test
//
// the expansion windows were reserved in the memory map and emitted into the C
// header long before the fabric decoded anything at those addresses, so an
// access to one returned zero and looked like working hardware. this is the
// test that says otherwise: attach a real slave in the window and require the
// data to come back.
//
// it runs against rtl generated from tb/exp_mcu.yaml, not from the board file,
// so what is being tested is the generator rather than one checked in netlist

module tb_exp;

  localparam time SYSCLK_HALF = 5ns;
  localparam time SWCLK_HALF  = 100ns;

  localparam logic [31:0] EXP_BASE = 32'h8000_0000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #SYSCLK_HALF clk = ~clk;

  logic swclk = 1'b0;
  logic host_dio = 1'b0;
  logic host_oe = 1'b0;
  wire  swdio;

  assign swdio = host_oe ? host_dio : 1'bz;
  pullup (swdio);

  integer errors = 0;

  // --- the mcu, with one expansion window brought out -----------------------
  wire        exp_hsel;
  wire [31:0] exp_haddr;
  wire        exp_hwrite;
  wire [1:0]  exp_htrans;
  wire [2:0]  exp_hsize;
  wire [31:0] exp_hwdata;
  wire        exp_hready;
  wire [31:0] exp_hrdata;
  wire        exp_hreadyout;

  wire        px0_psel, px1_psel;
  wire        px_penable, px_pwrite;
  wire [31:0] px_paddr, px_pwdata;
  wire [31:0] px0_prdata, px1_prdata;

  // open drain, so they need pull ups exactly as a board would
  wire i2c_scl, i2c_sda;
  pullup (i2c_scl);
  pullup (i2c_sda);

  m1core_mcu #(
    .ITCM_WORDS (4096),
    .DTCM_WORDS (2048),
    .GPIO_WIDTH (2)
  ) dut (
    .clk   (clk),
    .rst_n (rst_n),
    .swclk (swclk),
    .swdio (swdio),
    .led   (),
    .gpio  (),
    .uart0_rxd (1'b1),
    .uart0_txd (),
    // spi and i2c are here to prove the generator wires every peripheral type
    // out to the top correctly. the board does not carry them because both
    // need real pins
    .spi_sclk   (),
    .spi_mosi   (),
    .spi_miso   (1'b1),
    .spi_ssel_n (),
    .i2c_scl    (i2c_scl),
    .i2c_sda    (i2c_sda),
    .apbexp0_psel    (px0_psel),
    .apbexp0_penable (px_penable),
    .apbexp0_pwrite  (px_pwrite),
    .apbexp0_paddr   (px_paddr),
    .apbexp0_pwdata  (px_pwdata),
    .apbexp0_prdata  (px0_prdata),
    .apbexp0_pready  (1'b1),
    .apbexp1_psel    (px1_psel),
    .apbexp1_penable (),
    .apbexp1_pwrite  (),
    .apbexp1_paddr   (),
    .apbexp1_pwdata  (),
    .apbexp1_prdata  (px1_prdata),
    .apbexp1_pready  (1'b1),
    .ahbexp0_hsel      (exp_hsel),
    .ahbexp0_haddr     (exp_haddr),
    .ahbexp0_hwrite    (exp_hwrite),
    .ahbexp0_htrans    (exp_htrans),
    .ahbexp0_hsize     (exp_hsize),
    .ahbexp0_hwdata    (exp_hwdata),
    .ahbexp0_hready    (exp_hready),
    .ahbexp0_hrdata    (exp_hrdata),
    .ahbexp0_hreadyout (exp_hreadyout)
  );

  // --- a minimal user slave in the window -----------------------------------
  //
  // four registers, which is enough to prove the address reaches it. this is
  // also the smallest worked example of what attaching your own logic looks
  // like, so it is deliberately written the way a real one would be
  reg [31:0] user_regs [0:3];
  reg [31:0] addr_q;
  reg        write_q;
  reg        sel_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sel_q   <= 1'b0;
      write_q <= 1'b0;
      addr_q  <= 32'd0;
      user_regs[0] <= 32'd0;
      user_regs[1] <= 32'd0;
      user_regs[2] <= 32'd0;
      user_regs[3] <= 32'd0;
    end else begin
      // address phase is qualified by hready, exactly as for an internal slave
      if (exp_hready) begin
        sel_q   <= exp_hsel && exp_htrans[1];
        write_q <= exp_hwrite;
        addr_q  <= exp_haddr;
      end
      if (sel_q && write_q) begin
        user_regs[addr_q[3:2]] <= exp_hwdata;
      end
    end
  end

  assign exp_hrdata    = user_regs[addr_q[3:2]];
  assign exp_hreadyout = 1'b1;

  // --- two register blocks in the apb expansion window ----------------------
  //
  // this is the shape a cheby generated register map attaches in: one slot per
  // block, sharing the address and data phase, differing only in psel
  reg [31:0] px0_regs [0:3];
  reg [31:0] px1_regs [0:3];

  wire px0_wr = px0_psel && px_penable && px_pwrite;
  wire px1_wr = px1_psel && px_penable && px_pwrite;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      px0_regs[0] <= 32'd0; px0_regs[1] <= 32'd0;
      px0_regs[2] <= 32'd0; px0_regs[3] <= 32'd0;
      px1_regs[0] <= 32'd0; px1_regs[1] <= 32'd0;
      px1_regs[2] <= 32'd0; px1_regs[3] <= 32'd0;
    end else begin
      if (px0_wr) begin
        px0_regs[px_paddr[3:2]] <= px_pwdata;
      end
      if (px1_wr) begin
        px1_regs[px_paddr[3:2]] <= px_pwdata;
      end
    end
  end

  assign px0_prdata = px0_regs[px_paddr[3:2]];
  assign px1_prdata = px1_regs[px_paddr[3:2]];

  `include "swd_host.svh"

  task automatic expect32(input string what, input logic [31:0] got,
                          input logic [31:0] want);
    begin
      if (got !== want) begin
        $display("FAIL %-34s got %08x want %08x", what, got, want);
        errors = errors + 1;
      end else begin
        $display("ok   %-34s %08x", what, got);
      end
    end
  endtask

  logic [31:0] dpidr;
  logic [31:0] data;

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/tb_exp.vcd");
      $dumpvars(0, tb_exp);
    end

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    dap_init(dpidr);
    expect32("dpidr", dpidr, 32'h0c10_1477);

    // --- write through the window and check the slave saw it ---------------
    mem32_write(EXP_BASE + 32'h0, 32'hdead_beef);
    mem32_write(EXP_BASE + 32'h4, 32'h1234_5678);
    repeat (4) @(posedge clk);
    expect32("slave reg0 written", user_regs[0], 32'hdead_beef);
    expect32("slave reg1 written", user_regs[1], 32'h1234_5678);

    // --- and read it back through the fabric read mux -----------------------
    mem32_read(EXP_BASE + 32'h0, data);
    expect32("read back reg0", data, 32'hdead_beef);
    mem32_read(EXP_BASE + 32'h4, data);
    expect32("read back reg1", data, 32'h1234_5678);

    // the window is 16 MB, so the top of it decodes to the same slave. this is
    // what catches a decode written against the wrong address bits
    mem32_write(EXP_BASE + 32'h00ff_fff8, 32'ha5a5_a5a5);
    repeat (4) @(posedge clk);
    expect32("top of window decodes", user_regs[2], 32'ha5a5_a5a5);

    // one past the window must not reach the slave at all
    mem32_write(32'h8100_0000, 32'h0bad_0bad);
    repeat (4) @(posedge clk);
    expect32("outside window ignored", user_regs[0], 32'hdead_beef);

    // an unmapped read still returns zero rather than an error, which is what
    // stops a stray probe access latching stickyerr
    mem32_read(32'h9000_0000, data);
    expect32("unmapped reads zero", data, 32'h0000_0000);

    // --- apb expansion, sixteen 1 MB slots behind one bridge ----------------
    mem32_write(32'h6000_0000, 32'h1111_2222);
    mem32_write(32'h6010_0000, 32'h3333_4444);
    repeat (4) @(posedge clk);
    expect32("apb slot 0 written", px0_regs[0], 32'h1111_2222);
    expect32("apb slot 1 written", px1_regs[0], 32'h3333_4444);

    mem32_read(32'h6000_0000, data);
    expect32("apb slot 0 read back", data, 32'h1111_2222);
    mem32_read(32'h6010_0000, data);
    expect32("apb slot 1 read back", data, 32'h3333_4444);

    // a second register in the same slot, to prove the offset inside a window
    // reaches the block rather than only the slot decode working
    mem32_write(32'h6000_0008, 32'habcd_0001);
    repeat (4) @(posedge clk);
    expect32("apb offset within slot", px0_regs[2], 32'habcd_0001);

    // an enabled slot must not answer for its neighbour
    expect32("slot 1 untouched by slot 0", px1_regs[2], 32'h0000_0000);

    // a slot inside the window with nothing attached must still complete. if
    // pready never came back this read would hang the bus rather than fail
    mem32_read(32'h6020_0000, data);
    expect32("empty apb slot reads zero", data, 32'h0000_0000);

    if (errors == 0) begin
      $display("PASS");
    end else begin
      $display("FAIL %0d errors", errors);
    end
    $finish;
  end

endmodule

`default_nettype wire

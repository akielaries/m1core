`timescale 1ns/1ps
`default_nettype none

// basys 3 seven segment unit test
//
// drives the ahb side of the real ahb to apb bridge, the same path the cpu
// takes through the expansion window, into sevenseg and its cheby register
// file. checks register readback, blanking, the hex decode on every digit,
// raw mode and the decimal points, by watching the scanned pins the way the
// display sees them

module tb_sevenseg;

  localparam time CLK_HALF  = 10ns;    // 50 mhz, the basys 3 fabric clock
  localparam int  SCAN_BITS = 3;       // 8 clocks per digit instead of 65536

  localparam logic [31:0] CTRL  = 32'h00;
  localparam logic [31:0] VALUE = 32'h04;
  localparam logic [31:0] RAW   = 32'h08;
  localparam logic [31:0] DP    = 32'h0c;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #CLK_HALF clk = ~clk;

  integer errors = 0;

  logic        hsel = 1'b0;
  logic [31:0] haddr = 32'd0;
  logic        hwrite = 1'b0;
  logic [1:0]  htrans = 2'b00;
  logic [31:0] hwdata = 32'd0;
  wire  [31:0] hrdata;
  wire         hreadyout;

  wire        psel, penable, pwrite, pready;
  wire [31:0] paddr, pwdata, prdata;

  wire [3:0] an;
  wire [6:0] seg;
  wire       dp;

  ahb_apb_bridge u_bridge (
    .clk (clk), .rst_n (rst_n),
    .hsel (hsel), .haddr (haddr), .hwrite (hwrite), .htrans (htrans),
    .hready (hreadyout), .hwdata (hwdata), .hrdata (hrdata),
    .hreadyout (hreadyout),
    .psel (psel), .penable (penable), .pwrite (pwrite), .paddr (paddr),
    .pwdata (pwdata), .prdata (prdata), .pready (pready)
  );

  sevenseg #(.SCAN_BITS (SCAN_BITS)) u_dut (
    .clk (clk), .rst_n (rst_n),
    .psel (psel), .penable (penable), .pwrite (pwrite), .paddr (paddr),
    .pwdata (pwdata), .prdata (prdata), .pready (pready),
    .an (an), .seg (seg), .dp (dp)
  );

  // ---- ahb driver, as in tb_uart ----
  task automatic ahb_write(input logic [31:0] addr, input logic [31:0] data);
    begin
      @(posedge clk);
      hsel <= 1'b1; haddr <= addr; hwrite <= 1'b1; htrans <= 2'b10;
      @(posedge clk);
      hsel <= 1'b0; htrans <= 2'b00; hwdata <= data;
      #1;
      while (!hreadyout) begin
        @(posedge clk);
        #1;
      end
      @(posedge clk);
    end
  endtask

  task automatic ahb_read(input logic [31:0] addr, output logic [31:0] data);
    begin
      @(posedge clk);
      hsel <= 1'b1; haddr <= addr; hwrite <= 1'b0; htrans <= 2'b10;
      @(posedge clk);
      hsel <= 1'b0; htrans <= 2'b00;
      #1;
      while (!hreadyout) begin
        @(posedge clk);
        #1;
      end
      data = hrdata;
      @(posedge clk);
    end
  endtask

  task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] want);
    begin
      if (got !== want) begin
        $display("FAIL %-32s got %08x want %08x", what, got, want);
        errors = errors + 1;
      end else begin
        $display("ok   %-32s %08x", what, got);
      end
    end
  endtask

  // reference decode, written separately from the rtl's table. active high
  function automatic logic [6:0] hex7(input logic [3:0] n);
    logic [6:0] t [16] = '{7'h3f, 7'h06, 7'h5b, 7'h4f, 7'h66, 7'h6d, 7'h7d, 7'h07,
                           7'h7f, 7'h6f, 7'h77, 7'h7c, 7'h39, 7'h5e, 7'h79, 7'h71};
    return t[n];
  endfunction

  // wait until digit d is selected (its anode low, the others high), let it
  // settle a clock, and return what the segment and dp lines show, active high
  task automatic capture(input int d, output logic [6:0] lit, output logic dot);
    int guard;
    begin
      guard = 0;
      @(posedge clk);
      #1;
      while (an !== ~(4'b0001 << d)) begin
        @(posedge clk);
        #1;
        guard = guard + 1;
        if (guard > 1000) begin
          $display("FAIL digit %0d never selected, an=%b", d, an);
          errors = errors + 1;
          break;
        end
      end
      lit = ~seg;
      dot = ~dp;
    end
  endtask

  task automatic expect_digit(input string what, input int d, input logic [6:0] want_lit,
                              input logic want_dot);
    logic [6:0] lit;
    logic dot;
    begin
      capture(d, lit, dot);
      expect32($sformatf("%s digit %0d segs", what, d), {25'd0, lit}, {25'd0, want_lit});
      expect32($sformatf("%s digit %0d dp", what, d), {31'd0, dot}, {31'd0, want_dot});
    end
  endtask

  logic [31:0] data;
  int i;

  initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    // ---- reset state: registers zero, display dark ----
    ahb_read(CTRL, data);
    expect32("ctrl after reset", data, 32'h0);
    repeat (40) @(posedge clk);
    expect32("anodes off while disabled", {28'd0, an}, 32'hf);
    expect32("segments off while disabled", {25'd0, seg}, 32'h7f);

    // ---- register readback through the bridge ----
    ahb_write(VALUE, 32'hdead_1234);
    ahb_read(VALUE, data);
    expect32("value keeps 16 bits", data, 32'h0000_1234);
    ahb_write(RAW, 32'h7f06_5b4f);
    ahb_read(RAW, data);
    expect32("raw readback", data, 32'h7f06_5b4f);
    ahb_write(DP, 32'hffff_fff5);
    ahb_read(DP, data);
    expect32("dp keeps 4 bits", data, 32'h0000_0005);
    ahb_write(DP, 32'h0);

    // ---- hex mode, every nibble value on every digit position ----
    ahb_write(CTRL, 32'h1);
    for (i = 0; i < 16; i = i + 4) begin
      ahb_write(VALUE, {16'd0, 4'(i + 3), 4'(i + 2), 4'(i + 1), 4'(i)});
      expect_digit($sformatf("hex %x", i),     0, hex7(4'(i)),     1'b0);
      expect_digit($sformatf("hex %x", i + 1), 1, hex7(4'(i + 1)), 1'b0);
      expect_digit($sformatf("hex %x", i + 2), 2, hex7(4'(i + 2)), 1'b0);
      expect_digit($sformatf("hex %x", i + 3), 3, hex7(4'(i + 3)), 1'b0);
    end

    // ---- decimal points ----
    ahb_write(VALUE, 32'h1234);
    ahb_write(DP, 32'h4);
    expect_digit("dp", 1, hex7(4'h3), 1'b0);
    expect_digit("dp", 2, hex7(4'h2), 1'b1);

    // ---- raw mode, one byte per digit, bit 7 ignored ----
    ahb_write(DP, 32'h0);
    ahb_write(RAW, 32'h8140_0877);
    ahb_write(CTRL, 32'h3);
    expect_digit("raw", 0, 7'h77, 1'b0);
    expect_digit("raw", 1, 7'h08, 1'b0);
    expect_digit("raw", 2, 7'h40, 1'b0);
    expect_digit("raw", 3, 7'h01, 1'b0);

    // ---- disable blanks again ----
    ahb_write(CTRL, 32'h0);
    repeat (40) @(posedge clk);
    expect32("anodes off after disable", {28'd0, an}, 32'hf);

    $display("");
    if (errors == 0) begin
      $display("PASS");
    end else begin
      $display("FAIL, %0d error(s)", errors);
    end
    $finish;
  end

  initial begin
    #1ms;
    $display("FAIL timeout");
    $finish;
  end

endmodule

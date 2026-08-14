`timescale 1ns/1ps
`default_nettype none

// bridge and uart unit test
//
// drives the ahb side of the bridge directly rather than going through swd, so
// it runs in microseconds instead of milliseconds. checks the apb handshake, the
// cmsdk register layout, a real serial frame on the wire, and loopback

module tb_uart;

  localparam time CLK_HALF = 5ns;      // 100 mhz
  localparam int  BAUDDIV  = 16;       // clocks per bit, the cmsdk minimum

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #CLK_HALF clk = ~clk;

  integer errors = 0;

  // ahb side
  logic        hsel = 1'b0;
  logic [31:0] haddr = 32'd0;
  logic        hwrite = 1'b0;
  logic [1:0]  htrans = 2'b00;
  logic [31:0] hwdata = 32'd0;
  wire  [31:0] hrdata;
  wire         hreadyout;

  // apb side
  wire        psel, penable, pwrite, pready;
  wire [31:0] paddr, pwdata, prdata;

  wire txd, irq;
  logic rxd = 1'b1;

  ahb_apb_bridge u_bridge (
    .clk (clk), .rst_n (rst_n),
    .hsel (hsel), .haddr (haddr), .hwrite (hwrite), .htrans (htrans),
    .hready (hreadyout), .hwdata (hwdata), .hrdata (hrdata),
    .hreadyout (hreadyout),
    .psel (psel), .penable (penable), .pwrite (pwrite), .paddr (paddr),
    .pwdata (pwdata), .prdata (prdata), .pready (pready)
  );

  apb_uart u_uart (
    .clk (clk), .rst_n (rst_n),
    .psel (psel), .penable (penable), .pwrite (pwrite), .paddr (paddr),
    .pwdata (pwdata), .prdata (prdata), .pready (pready),
    .rxd (rxd), .txd (txd), .irq (irq)
  );

  // ---- ahb driver ----
  task automatic ahb_write(input logic [31:0] addr, input logic [31:0] data);
    begin
      @(posedge clk);
      hsel <= 1'b1; haddr <= addr; hwrite <= 1'b1; htrans <= 2'b10;
      @(posedge clk);
      hsel <= 1'b0; htrans <= 2'b00; hwdata <= data;
      // hold the data phase until the bridge reports ready. sampled a delta
      // after the edge so the dut's nonblocking updates have settled
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
        $display("FAIL %-28s got %08x want %08x", what, got, want);
        errors = errors + 1;
      end else begin
        $display("ok   %-28s %08x", what, got);
      end
    end
  endtask

  // ---- decode a frame off the wire, independently of the transmitter ----
  task automatic capture_frame(output logic [7:0] byte_out);
    integer i;
    begin
      @(negedge txd);                       // start bit
      repeat (BAUDDIV + BAUDDIV/2) @(posedge clk);   // into the middle of bit 0
      for (i = 0; i < 8; i = i + 1) begin
        byte_out[i] = txd;
        repeat (BAUDDIV) @(posedge clk);
      end
      if (txd !== 1'b1) begin
        $display("FAIL stop bit not high");
        errors = errors + 1;
      end
    end
  endtask

  // ---- shift a byte in on rxd ----
  task automatic send_frame(input logic [7:0] b);
    integer i;
    begin
      rxd = 1'b0;                                    // start
      repeat (BAUDDIV) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        rxd = b[i];
        repeat (BAUDDIV) @(posedge clk);
      end
      rxd = 1'b1;                                    // stop
      repeat (BAUDDIV * 2) @(posedge clk);
    end
  endtask

  localparam logic [31:0] UART = 32'h5000_4000;

  logic [31:0] data;
  logic [7:0]  got;

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_uart.vcd");
      $dumpvars(0, tb_uart);
    end

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // --- registers, through the bridge ---
    ahb_read(UART + 32'h10, data);
    expect32("bauddiv reset value", data, 32'd16);

    ahb_write(UART + 32'h10, BAUDDIV);
    ahb_read(UART + 32'h10, data);
    expect32("bauddiv readback", data, BAUDDIV);

    ahb_write(UART + 32'h08, 32'h3);          // TXEN | RXEN
    ahb_read(UART + 32'h08, data);
    expect32("ctrl readback", data, 32'h0000_0003);

    ahb_read(UART + 32'h04, data);
    expect32("state idle", data, 32'h0000_0000);

    // --- transmit, and decode what actually comes out of the pin ---
    fork
      begin
        ahb_write(UART + 32'h00, 32'h0000_0041);   // 'A'
      end
      begin
        capture_frame(got);
      end
    join
    expect32("tx byte on the wire", {24'd0, got}, 32'h0000_0041);

    // the stop bit is still going when capture_frame returns, so wait for the
    // transmitter to actually finish before looking at the interrupt
    data = 32'hffff_ffff;
    while (data[0]) begin
      ahb_read(UART + 32'h04, data);
    end
    expect32("txbf clears when done", data & 32'h1, 32'h0);

    // txirq should be pending once the frame completes
    ahb_read(UART + 32'h0c, data);
    expect32("txirq pending", data & 32'h1, 32'h1);
    ahb_write(UART + 32'h0c, 32'h1);               // write one to clear
    ahb_read(UART + 32'h0c, data);
    expect32("txirq cleared", data & 32'h1, 32'h0);

    // --- receive ---
    send_frame(8'h5a);
    ahb_read(UART + 32'h04, data);
    expect32("rxbf set after frame", data & 32'h2, 32'h2);
    ahb_read(UART + 32'h00, data);
    expect32("rx byte", data, 32'h0000_005a);
    ahb_read(UART + 32'h04, data);
    expect32("rxbf clears on read", data & 32'h2, 32'h0);

    // --- overrun: a second byte with the buffer still full ---
    send_frame(8'h11);
    send_frame(8'h22);
    ahb_read(UART + 32'h04, data);
    expect32("rx overrun flagged", data & 32'h8, 32'h8);
    ahb_write(UART + 32'h04, 32'h8);               // write one to clear
    ahb_read(UART + 32'h04, data);
    expect32("rx overrun cleared", data & 32'h8, 32'h0);

    $display("");
    if (errors == 0) begin
      $display("PASS");
    end else begin
      $display("FAIL, %0d error(s)", errors);
    end
    $finish;
  end

  initial begin
    #5ms;
    $display("FAIL timeout");
    $finish;
  end

endmodule

`default_nettype wire

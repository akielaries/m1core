`timescale 1ns/1ps
`default_nettype none

// the whole system, end to end
//
// the core comes out of reset, runs the hello app from itcm, drives the ahb
// fabric into the apb bridge, and the testbench decodes real serial frames off
// the txd pin. nothing is stubbed: if this passes, the cpu, the fabric, the
// bridge's wait state handling and the uart all work together
//
// uses a small BAUDDIV so a frame takes microseconds rather than milliseconds

module tb_hello;

  localparam time SYSCLK_HALF = 5ns;
  localparam int  BAUDDIV     = 16;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #SYSCLK_HALF clk = ~clk;

  wire swdio;
  pullup (swdio);

  wire [1:0] gpio_pins;
  wire       txd;

  m1core_soc #(
    .ITCM_WORDS (4096),
    .DTCM_WORDS (2048),
    .GPIO_WIDTH (2),
    .ITCM_INIT  ("../sw/apps/hello/build-sim/hello_sim.hex")
  ) dut (
    .clk   (clk),
    .rst_n (rst_n),
    .swclk (1'b0),
    .swdio (swdio),
    .led   (),
    .gpio  (gpio_pins),
    .uart0_rxd (1'b1),
    .uart0_txd (txd),
    .uart0_irq ()
  );

  integer errors = 0;

  // ---- decode frames off the pin, independently of the transmitter ----
  string  captured;
  integer nchars = 0;

  task automatic capture_frame(output logic [7:0] b);
    integer i;
    begin
      @(negedge txd);
      repeat (BAUDDIV + BAUDDIV/2) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        b[i] = txd;
        repeat (BAUDDIV) @(posedge clk);
      end
    end
  endtask

  logic [7:0] ch;

  initial begin
    captured = "";
    forever begin
      capture_frame(ch);
      if (ch >= 8'h20 && ch < 8'h7f) begin
        captured = {captured, string'(ch)};
      end else if (ch == 8'h0a) begin
        captured = {captured, "|"};
      end
      nchars = nchars + 1;
    end
  end

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_hello.vcd");
      $dumpvars(0, tb_hello);
    end

    repeat (10) @(posedge clk);
    rst_n = 1'b1;

    // enough characters to get the banner plus a couple of tick lines
    wait (nchars >= 40);
    repeat (100) @(posedge clk);

    $display("uart output: %s", captured);

    if (captured.substr(0, 11) != "m1core alive") begin
      $display("FAIL banner not received, got \"%s\"", captured.substr(0, 11));
      errors = errors + 1;
    end else begin
      $display("ok   banner received over uart");
    end

    // the tick lines prove the core is looping and the hex formatter works,
    // which needs the libgcc helpers linked in
    if (captured.len() < 30 || !(captured.substr(13, 16) == "tick")) begin
      $display("FAIL tick line missing");
      errors = errors + 1;
    end else begin
      $display("ok   tick line received");
    end

    if (gpio_pins === 2'b00) begin
      $display("FAIL gpio never driven");
      errors = errors + 1;
    end else begin
      $display("ok   gpio driven by firmware   %b", gpio_pins);
    end

    $display("");
    if (errors == 0) begin
      $display("PASS");
    end else begin
      $display("FAIL, %0d error(s)", errors);
    end
    $finish;
  end

  initial begin
    #50ms;
    $display("FAIL timeout, captured \"%s\"", captured);
    $display("FAIL");
    $finish;
  end

endmodule

`default_nettype wire

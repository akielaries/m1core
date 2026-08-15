`timescale 1ns/1ps
`default_nettype none

// the whole point of the project, in one testbench: the core comes out of
// reset, runs the blink firmware from itcm, and the gpio pin actually moves
//
// uses the short delay build, the real one takes millions of cycles per toggle

module tb_blink;

  localparam time SYSCLK_HALF = 5ns;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #SYSCLK_HALF clk = ~clk;

  wire swdio;
  pullup (swdio);

  wire [1:0] gpio_pins;

  m1core_soc #(
    .ITCM_WORDS (4096),
    .DTCM_WORDS (2048),
    .GPIO_WIDTH (2),
    .ITCM_INIT  ("../sw/baremetal/apps/blink/build-sim/blink_sim.hex")
  ) dut (
    .clk   (clk),
    .rst_n (rst_n),
    .swclk (1'b0),
    .swdio (swdio),
    .led   (),
    .gpio  (gpio_pins),
    .uart0_rxd (1'b1),
    .uart0_txd (),
    .uart0_irq ()
  );

  integer edges = 0;
  logic   prev = 1'b0;
  integer errors = 0;

  always @(posedge clk) begin
    if (rst_n) begin
      if (gpio_pins[0] !== prev) begin
        edges = edges + 1;
        $display("     gpio[0] -> %b  at %0t", gpio_pins[0], $time);
        prev = gpio_pins[0];
      end
    end
  end

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_blink.vcd");
      $dumpvars(0, tb_blink);
    end

    repeat (10) @(posedge clk);
    rst_n = 1'b1;

    // wait for a few toggles, which means the loop is actually looping
    wait (edges >= 4);

    // dir must have been programmed by the firmware, not left at reset
    if (dut.u_gpio.dir_r !== 2'b11) begin
      $display("FAIL gpio dir not programmed by firmware: %b", dut.u_gpio.dir_r);
      errors = errors + 1;
    end else begin
      $display("ok   firmware programmed gpio dir");
    end

    if (errors == 0) begin
      $display("ok   core executed blink, %0d gpio transitions", edges);
      $display("");
      $display("PASS");
    end else begin
      $display("");
      $display("FAIL, %0d error(s)", errors);
    end
    $finish;
  end

  initial begin
    #20ms;
    $display("FAIL timeout, gpio never toggled, pc=%08x", dut.u_core.pc);
    $display("FAIL");
    $finish;
  end

endmodule

`default_nettype wire

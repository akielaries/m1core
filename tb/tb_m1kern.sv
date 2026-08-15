`timescale 1ns/1ps
`default_nettype none

// m1kern running on m1core
//
// loads the 01_blink example: two equal priority threads, one toggling LED0
// every 250 ms and the other LED1 every 500 ms, both via thread_sleep_ms.
//
// watching those two pins is a complete proof of the port. LED1 only toggles
// if SysTick advances system_time_ms, if thread_sleep_ms wakes, and if PendSV
// switches between the two threads. a 2:1 edge ratio means both are being
// scheduled fairly rather than one starving the other
//
// built with a low SYSTEM_CLOCK_HZ so the tick and the uart divider are small
// enough to simulate. see the m1kern target in sim/Makefile

module tb_m1kern;

  localparam time SYSCLK_HALF = 5ns;
  // must match what the firmware programs: SYSTEM_CLOCK_HZ / console baud,
  // integer divided. see the m1kern target in sim/Makefile
  localparam int  BAUDDIV     = 4000000 / 115200;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #SYSCLK_HALF clk = ~clk;

  wire swdio;
  pullup (swdio);

  wire [1:0] gpio_pins;
  wire       txd;

  // sized to match targets/m1core/bsp/startup/linker/m1core.ld
  m1core_soc #(
    .ITCM_WORDS (8192),
    .DTCM_WORDS (4096),
    .GPIO_WIDTH (2),
    .ITCM_INIT  ("build/m1kern.hex")
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
  integer edges0 = 0;
  integer edges1 = 0;
  logic   prev0 = 1'b0;
  logic   prev1 = 1'b0;

  always @(posedge clk) begin
    if (rst_n) begin
      if (gpio_pins[0] !== prev0) begin
        edges0 = edges0 + 1;
        prev0 = gpio_pins[0];
      end
      if (gpio_pins[1] !== prev1) begin
        edges1 = edges1 + 1;
        prev1 = gpio_pins[1];
      end
    end
  end

  string  captured;
  integer nchars = 0;
  integer nlines = 0;

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
      nchars = nchars + 1;
      if (ch == 8'h0a) begin
        $display("uart: %s", captured);
        captured = "";
        nlines = nlines + 1;
      end else if (ch >= 8'h20 && ch < 8'h7f) begin
        captured = {captured, string'(ch)};
      end
    end
  end

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_m1kern.vcd");
      $dumpvars(0, tb_m1kern);
    end

    repeat (10) @(posedge clk);
    rst_n = 1'b1;

    // the banner, then at least one monitor report from the scheduler
    wait (nlines >= 2);
    $display("ok   kernel booted, %0d lines over uart", nlines);

    // let the two blink threads run until the slow one has toggled a few times
    wait (edges1 >= 6);
    repeat (100) @(posedge clk);

    $display("     gpio0 edges=%0d gpio1 edges=%0d", edges0, edges1);

    if (edges0 == 0 || edges1 == 0) begin
      $display("FAIL a blink thread never ran");
      errors = errors + 1;
    end else begin
      $display("ok   both blink threads scheduled");
    end

    // led0 is 250 ms and led1 is 500 ms, so led0 should toggle about twice as
    // often. allow slack for where the run happens to stop
    if (edges0 < (edges1 * 3) / 2 || edges0 > edges1 * 3) begin
      $display("FAIL edge ratio %0d:%0d is not roughly 2:1", edges0, edges1);
      errors = errors + 1;
    end else begin
      $display("ok   edge ratio is roughly 2:1, threads share fairly");
    end

    if (errors == 0) begin
      $display("");
      $display("PASS");
    end else begin
      $display("");
      $display("FAIL, %0d error(s)", errors);
    end
    $finish;
  end

  // periodic snapshot, so a stuck kernel says where it is stuck
  initial begin
    if ($test$plusargs("pc")) begin
      forever begin
        #500us;
        $display("%8t pc=%08x st=%2d ipsr=%2d hnd=%b sp=%08x prio=%0d chars=%0d",
                 $time, dut.u_core.pc, dut.u_core.state, dut.u_core.ipsr,
                 dut.u_core.mode_handler, dut.u_core.sp_read,
                 dut.u_core.cur_prio, nchars);
      end
    end
  end

  initial begin
    #400ms;
    $display("FAIL timeout after %0d chars, partial line \"%s\"", nchars, captured);
    $display("FAIL");
    $finish;
  end

endmodule

`default_nettype wire

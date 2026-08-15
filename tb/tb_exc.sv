`timescale 1ns/1ps
`default_nettype none

// runs the self checking exception test on the core, no debugger involved
//
// itcm is preloaded with the image the way a bitstream would be, the core comes
// out of reset, reads sp and pc from the vector table, and runs. the test
// reports through dtcm:
//   0x20000000 error count, 0x20000004 first failing test id,
//   0x20000008 completion marker

module tb_exc;

  localparam time SYSCLK_HALF = 5ns;

  localparam logic [31:0] DONE_MAGIC = 32'h600d_c0de;

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
    .ITCM_INIT  ("../sw/baremetal/tests/exc/build/exctest.hex")
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

  // the test writes its results to the bottom of dtcm
  wire [31:0] r_errors = dut.u_dtcm.mem[0];
  wire [31:0] r_firstid = dut.u_dtcm.mem[1];
  wire [31:0] r_done   = dut.u_dtcm.mem[2];

  // exception trace
  always @(posedge clk) begin
    if ($test$plusargs("exc") && rst_n) begin
      if (dut.u_core.exc_taken) begin
        $display("%8t ENTER exc=%0d ret=%08x prio=%0d->%0d sp=%08x", $time,
                 dut.u_core.exc_taken_num, dut.u_core.exc_ret_addr,
                 dut.u_core.cur_prio, dut.u_core.exc_new_prio,
                 dut.u_core.sp_read);
      end
      // word 6 of the frame is the return address, word 7 is xpsr
      if (dut.u_core.state == 5'd19 && dut.u_core.exc_cnt == 3'd6) begin
        $display("%8t EXIT  ret=%08x pc<=%08x frame=%08x", $time,
                 dut.u_core.exc_return, dut.u_core.bus_rdata,
                 dut.u_core.exc_frame);
      end
    end
  end

  integer cycles;
  integer traced = 0;

  // ST_EXEC lasts exactly one cycle per instruction, so counting cycles spent
  // there counts instructions retired
  integer instrs = 0;

  always @(posedge clk) begin
    if (rst_n && dut.u_core.state == 5'd9) begin
      instrs = instrs + 1;
    end
  end

  // instruction trace, state 9 is ST_EXEC
  always @(posedge clk) begin
    if ($test$plusargs("trace") && dut.u_core.state == 5'd9 && traced < 400) begin
      traced = traced + 1;
      $display("%4d pc=%08x inst=%04x r0=%08x r1=%08x r2=%08x r4=%0d r6=%0d r7=%0d nzcv=%b%b%b%b",
               traced, dut.u_core.pc, dut.u_core.inst,
               dut.u_core.regs[0], dut.u_core.regs[1], dut.u_core.regs[2],
               dut.u_core.regs[4], dut.u_core.regs[6], dut.u_core.regs[7],
               dut.u_core.n_flag, dut.u_core.z_flag,
               dut.u_core.c_flag, dut.u_core.v_flag);
    end
  end

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_exc.vcd");
      $dumpvars(0, tb_exc);
    end

    repeat (10) @(posedge clk);
    rst_n = 1'b1;

    // wait for the completion marker
    cycles = 0;
    while (r_done !== DONE_MAGIC && cycles < 2000000) begin
      @(posedge clk);
      cycles = cycles + 1;
    end

    $display("");
    if (r_done !== DONE_MAGIC) begin
      $display("FAIL exception test never completed, pc=%08x state=%0d after %0d cycles",
               dut.u_core.pc, dut.u_core.state, cycles);
      $display("FAIL");
    end else if (r_errors !== 32'd0) begin
      $display("FAIL %0d instruction check(s) failed, first failing test id %0d",
               r_errors, r_firstid);
      $display("     deep=%0d pendsv=%0d failmask=%b of %0d checks",
               dut.u_dtcm.mem[3], dut.u_dtcm.mem[4],
               dut.u_dtcm.mem[5], dut.u_dtcm.mem[6]);
      $display("FAIL");
    end else begin
      $display("ok   exception test completed in %0d cycles", cycles);
      $display("ok   all exception checks passed");
      $display("     %0d instructions, CPI %0.2f", instrs, real'(cycles) / instrs);
      $display("     at 25 MHz that is %0.2f MIPS", 25.0 * instrs / cycles);
      $display("");
      $display("PASS");
    end
    $finish;
  end

  initial begin
    #200ms;
    $display("FAIL hard timeout");
    $finish;
  end

endmodule

`default_nettype wire

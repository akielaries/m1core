`timescale 1ns/1ps
`default_nettype none

// runs the self checking isa test on the core, no debugger involved
//
// itcm is preloaded with the image the way a bitstream would be, the core comes
// out of reset, reads sp and pc from the vector table, and runs. the test
// reports through dtcm:
//   0x20000000 error count, 0x20000004 first failing test id,
//   0x20000008 completion marker

`include "m1core_clock.vh"

module tb_core;

  localparam time SYSCLK_HALF = 5ns;

  localparam logic [31:0] DONE_MAGIC = 32'h600d_c0de;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #SYSCLK_HALF clk = ~clk;

  wire swdio;
  pullup (swdio);

  wire [1:0] gpio_pins;

  m1core_mcu #(
    .ITCM_WORDS (4096),
    .DTCM_WORDS (2048),
    .GPIO_WIDTH (2),
    .ITCM_INIT  ("../sw/baremetal/tests/isa/build/isatest.hex")
  ) dut (
    .clk   (clk),
    .rst_n (rst_n),
    .swclk (1'b0),
    .swdio (swdio),
    .led   (),
    .gpio  (gpio_pins),
    .uart0_rxd (1'b1),
    .uart0_txd ()
  );

  // the test writes its results to the bottom of dtcm
  wire [31:0] r_errors = dut.u_dtcm.mem[0];
  wire [31:0] r_firstid = dut.u_dtcm.mem[1];
  wire [31:0] r_done   = dut.u_dtcm.mem[2];

  integer cycles;
  integer traced = 0;

  // ST_EXEC lasts exactly one cycle per instruction, so counting cycles spent
  // there counts instructions retired
  integer instrs = 0;

  always @(posedge clk) begin
`ifdef M1CORE_FORCE_MULTICYCLE
    if (rst_n && dut.u_core.state == 5'd9) begin
      instrs = instrs + 1;
    end
`elsif M1CORE_PIPELINE
    // the pipelined core has no single execute state: an instruction retires
    // when execute holds a valid one and is not stalled behind a memory access
    if (rst_n && dut.u_core.e_v && !dut.u_core.e_busy) begin
      instrs = instrs + 1;
    end
`else
    if (rst_n && dut.u_core.state == 5'd9) begin
      instrs = instrs + 1;
    end
`endif
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

  // where the cycles go. cpi is one number and it does not say which state is
  // spending them, so count occupancy per state. names track m1core_cpu.v
  int unsigned st_count [0:31];
  string       st_name  [0:31];
  int unsigned i2;

  initial begin
    for (i2 = 0; i2 < 32; i2 = i2 + 1) begin
      st_count[i2] = 0;
      st_name[i2]  = "";
    end
    st_name[5]  = "FETCH_A";   st_name[6]  = "FETCH_D";
    st_name[7]  = "FETCH2_A";  st_name[8]  = "FETCH2_D";
    st_name[9]  = "EXEC";      st_name[10] = "MEM_A";
    st_name[11] = "MEM_D";     st_name[12] = "MULTI_A";
    st_name[13] = "MULTI_D";   st_name[20] = "DECODE";
  end

  always @(posedge clk) begin
    if (rst_n) begin
      st_count[dut.u_core.state] <= st_count[dut.u_core.state] + 1;
    end
  end

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_core.vcd");
      $dumpvars(0, tb_core);
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
      $display("FAIL isa test never completed, pc=%08x state=%0d after %0d cycles",
               dut.u_core.pc, dut.u_core.state, cycles);
      $display("FAIL");
    end else if (r_errors !== 32'd0) begin
      $display("FAIL %0d instruction check(s) failed, first failing test id %0d",
               r_errors, r_firstid);
      $display("FAIL");
    end else begin
      $display("ok   isa test completed in %0d cycles", cycles);
      $display("ok   all instruction checks passed");
      $display("     %0d instructions, CPI %0.2f", instrs, real'(cycles) / instrs);
      $display("     at %0.0f MHz that is %0.2f MIPS",
               `SYSTEM_CLOCK_HZ / 1.0e6,
               (`SYSTEM_CLOCK_HZ / 1.0e6) * instrs / cycles);
      $display("");
      $display("");
      $display("     cycles by state:");
      for (i2 = 0; i2 < 32; i2 = i2 + 1) begin
        if (st_count[i2] != 0) begin
          $display("       %0d %-9s %6d  %5.1f%%", i2, st_name[i2],
                   st_count[i2], 100.0 * st_count[i2] / cycles);
        end
      end
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

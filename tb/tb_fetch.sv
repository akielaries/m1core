// fetch unit test
//
// the 3-stage core's whole throughput claim rests on this unit issuing one
// access per cycle and never handing decode a wrong halfword, so it is tested
// on its own before anything is built on top of it.
//
// the memory is arranged so every halfword equals its own address divided by
// two. that makes the check an invariant rather than a table: whatever comes
// out, inst must equal pc >> 1. a misaligned redirect, a flushed in-flight
// fetch or an off-by-one queue index all break it immediately.

`timescale 1ns/1ps

module tb_fetch;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  reg         redirect = 0;
  reg  [31:0] redirect_pc = 0;
  reg         stall = 0;
  reg         hold_off = 0;
  wire        f_req;
  wire [31:0] f_addr;
  reg  [31:0] f_rdata;
  wire        f_valid, f_valid2;
  wire [15:0] f_inst;
  wire [31:0] f_pc;
  reg         f_pop = 0;

  // the arbiter is combinational and a data access steals the bus
  wire f_gnt = f_req && !hold_off;

  m1core_fetch #(.DEPTH(8)) dut (
    .clk(clk), .rst_n(rst_n),
    .redirect(redirect), .redirect_pc(redirect_pc),
    .stall(stall), .hold_off(hold_off),
    .f_req(f_req), .f_addr(f_addr), .f_gnt(f_gnt), .f_rdata(f_rdata),
    .f_valid(f_valid), .f_inst(f_inst), .f_pc(f_pc), .f_pop(f_pop),
    .f_pop2(1'b0), .f_inst2(),
    .f_valid2(f_valid2)
  );

  // one cycle of read latency, exactly like ahb_sram
  reg [31:0] acc_addr;
  reg        acc_v;
  integer    accesses = 0;
  always @(posedge clk) begin
    acc_v <= f_req && f_gnt;
    if (f_req && f_gnt) begin
      acc_addr <= f_addr;
      accesses <= accesses + 1;
    end
  end
  always @* begin
    f_rdata = {acc_addr[16:1] + 16'd1, acc_addr[16:1]};
  end

  integer errs = 0, popped = 0;
  reg [31:0] expect_pc;

  task check_pop(input [31:0] want_pc);
    begin
      // wait for a halfword to be available, then take it
      while (!f_valid) @(posedge clk);
      if (f_pc !== want_pc) begin
        errs = errs + 1;
        if (errs < 10) $display("  FAIL pc: want %08x got %08x", want_pc, f_pc);
      end else if (f_inst !== want_pc[16:1]) begin
        errs = errs + 1;
        if (errs < 10) $display("  FAIL inst at %08x: want %04x got %04x",
                                want_pc, want_pc[16:1], f_inst);
      end
      f_pop = 1;
      @(posedge clk);
      f_pop = 0;
      popped = popped + 1;
    end
  endtask

  integer i;
  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ---- 1. sequential stream from zero ----
    redirect = 1; redirect_pc = 32'h0000_0000; @(posedge clk); redirect = 0;
    expect_pc = 32'h0000_0000;
    for (i = 0; i < 24; i = i + 1) begin
      check_pop(expect_pc);
      expect_pc = expect_pc + 2;
    end
    $display("ok   sequential stream, %0d halfwords", popped);

    // ---- 2. redirect to a halfword aligned target ----
    // the low half of the containing word must be discarded, not delivered
    redirect = 1; redirect_pc = 32'h0000_0112; @(posedge clk); redirect = 0;
    expect_pc = 32'h0000_0112;
    for (i = 0; i < 8; i = i + 1) begin
      check_pop(expect_pc);
      expect_pc = expect_pc + 2;
    end
    $display("ok   misaligned redirect discards the low halfword");

    // ---- 3. redirect while an access is in flight ----
    // the in-flight data still returns and must be thrown away
    redirect = 1; redirect_pc = 32'h0000_0200; @(posedge clk); redirect = 0;
    @(posedge clk);
    redirect = 1; redirect_pc = 32'h0000_0300; @(posedge clk); redirect = 0;
    expect_pc = 32'h0000_0300;
    for (i = 0; i < 8; i = i + 1) begin
      check_pop(expect_pc);
      expect_pc = expect_pc + 2;
    end
    $display("ok   redirect over an in-flight fetch");

    // ---- 4. the bus is stolen by a data access ----
    redirect = 1; redirect_pc = 32'h0000_0400; @(posedge clk); redirect = 0;
    expect_pc = 32'h0000_0400;
    check_pop(expect_pc); expect_pc = expect_pc + 2;
    hold_off = 1;
    repeat (6) @(posedge clk);
    hold_off = 0;
    for (i = 0; i < 8; i = i + 1) begin
      check_pop(expect_pc);
      expect_pc = expect_pc + 2;
    end
    $display("ok   stream survives losing the bus");

    // ---- 5. throughput: pop every cycle and count accesses ----
    redirect = 1; redirect_pc = 32'h0000_0500; @(posedge clk); redirect = 0;
    begin : thruput
      integer start_acc, cycles, got;
      // let the queue fill first
      repeat (6) @(posedge clk);
      start_acc = accesses; got = 0; cycles = 0;
      f_pop = 1;
      for (cycles = 0; cycles < 40; cycles = cycles + 1) begin
        @(posedge clk);
        if (f_valid) got = got + 1;
      end
      f_pop = 0;
      $display("ok   throughput: %0d halfwords in 40 cycles, %0d bus accesses",
               got, accesses - start_acc);
      if (got < 38) begin
        errs = errs + 1;
        $display("  FAIL sustained rate too low: %0d of 40", got);
      end
    end

    if (errs == 0) begin
      $display("PASS");
    end else begin
      $display("FAIL, %0d errors", errs);
    end
    $finish;
  end

  initial begin
    #200000;
    $display("FAIL timeout");
    $finish;
  end

endmodule

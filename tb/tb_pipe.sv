// 3-stage core, phase 2: fetch/decode/execute
//
// hand assembled so the test has no toolchain dependency and the encodings are
// visible next to what they should do. the program is chosen to hit the three
// things that are new in this phase rather than to cover the isa:
//
//   adds r2,r0,r1   reads both registers written by the two instructions
//                   immediately before it, so it fails without forwarding
//   ldr after str   exercises the two-cycle memory phase and the load forward
//   beq             resolves in E and must squash the instruction already in D
//
// the full instruction set is covered by the existing 148-check suite once the
// escape path lands and this core can run it.

`timescale 1ns/1ps

module tb_pipe;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  wire        bus_req, bus_write;
  wire [31:0] bus_addr, bus_wdata;
  wire [2:0]  bus_size;
  reg  [31:0] bus_rdata;
  wire        unsupported;

  // always grant, zero wait states, one cycle of read latency: ahb_sram
  wire bus_gnt   = bus_req;
  wire bus_ready = 1'b1;

  // the tcm ports are plain synchronous memory: one cycle, no handshake
  wire        itcm_en, dtcm_en, dtcm_write;
  wire [31:0] itcm_addr, dtcm_addr, dtcm_wdata;
  wire [3:0]  dtcm_be;
  reg  [31:0] itcm_rdata;

  m1core_cpu_p dut (
    .clk(clk), .rst_n(rst_n),
    .bus_req(bus_req), .bus_addr(bus_addr), .bus_write(bus_write),
    .bus_size(bus_size), .bus_wdata(bus_wdata),
    .bus_gnt(bus_gnt), .bus_ready(bus_ready), .bus_rdata(bus_rdata),
    .dbg_en(1'b0), .sys_reset_req(1'b0), .vc_corereset(1'b0),
    .dbg_halt_req(1'b0), .dbg_step_req(1'b0),
    .dbg_halted(), .dbg_halt_event(), .dbg_bkpt_hit(), .dbg_lockup(),
    .pend_valid(1'b0), .pend_num(6'd0), .pend_prio(3'd0),
    .exc_taken(), .exc_taken_num(),
    .dreg_req(1'b0), .dreg_wnr(1'b0), .dreg_sel(5'd0), .dreg_wdata(32'd0),
    .dreg_ack(), .dreg_rdata(),
    .itcm_en(itcm_en), .itcm_addr(itcm_addr), .itcm_rdata(itcm_rdata),
    .dtcm_en(dtcm_en), .dtcm_addr(dtcm_addr), .dtcm_write(dtcm_write),
    .dtcm_be(dtcm_be), .dtcm_wdata(dtcm_wdata), .dtcm_rdata(32'd0),
    .unsupported(unsupported)
  );


  reg [31:0] mem [0:255];
  reg [31:0] rdata_r;
  wire [7:0] widx = bus_addr[9:2];

  // ahb, not a single-cycle memory: the address phase captures the request and
  // the data phase carries hwdata. modelling the write in the address phase
  // reads the master's wdata a cycle early, which is not what a real slave
  // sees and hid a store bug the real ahb_sram caught immediately
  reg [7:0] a_idx;
  reg       a_v, a_w;
  reg [2:0] a_size;
  reg [1:0] a_byte;

  always @(posedge clk) begin
    a_v <= bus_req && bus_gnt;
    if (bus_req && bus_gnt) begin
      a_idx  <= widx;
      a_w    <= bus_write;
      a_size <= bus_size;
      a_byte <= bus_addr[1:0];
      if (!bus_write) begin
        rdata_r <= mem[widx];
      end
    end
    if (a_v && a_w) begin
      case (a_size)
        3'd0: case (a_byte)
                2'd0: mem[a_idx][7:0]   <= bus_wdata[7:0];
                2'd1: mem[a_idx][15:8]  <= bus_wdata[15:8];
                2'd2: mem[a_idx][23:16] <= bus_wdata[23:16];
                default: mem[a_idx][31:24] <= bus_wdata[31:24];
              endcase
        3'd1: if (a_byte[1]) begin
                mem[a_idx][31:16] <= bus_wdata[31:16];
              end else begin
                mem[a_idx][15:0]  <= bus_wdata[15:0];
              end
        default: mem[a_idx] <= bus_wdata;
      endcase
    end
  end
  always @* begin
    bus_rdata = rdata_r;
  end

  always @(posedge clk) begin
    if (itcm_en) begin
      itcm_rdata <= mem[itcm_addr[9:2]];
    end
  end

  // cpi over the straight-line part, stopping at the spin so the infinite
  // loop does not dominate the average
  integer cycles = 0, retired = 0;
  reg     done = 0;
  always @(posedge clk) begin
    if (rst_n && (dut.state == 4'd4) && !done) begin
      cycles <= cycles + 1;
      if (dut.e_v && !dut.e_busy) begin
        retired <= retired + 1;
        if (dut.e_pc == 32'h26) begin
          done <= 1;
        end
      end
    end
  end

  integer errs = 0;
  task chk(input [8*10:1] name, input [31:0] got, input [31:0] want);
    begin
      if (got !== want) begin
        errs = errs + 1;
        $display("  FAIL %0s: want %08x got %08x", name, want, got);
      end
    end
  endtask

  integer i;
  initial begin
    for (i = 0; i < 256; i = i + 1) begin
      mem[i] = 32'd0;
    end

    // vector table
    mem[0] = 32'h0000_0100;   // initial sp
    mem[1] = 32'h0000_0009;   // initial pc, thumb bit set -> 0x08

    // 0x08 movs r0,#5          r0 = 5
    // 0x0a movs r1,#3          r1 = 3
    mem[2] = {16'h2103, 16'h2005};
    // 0x0c adds r2,r0,r1       r2 = 8   (needs forwarding from both)
    // 0x0e subs r3,r0,r1       r3 = 2
    mem[3] = {16'h1a43, 16'h1842};
    // 0x10 lsls r4,r0,#2       r4 = 20
    // 0x12 movs r5,#0x40       r5 = 0x40
    mem[4] = {16'h2540, 16'h0084};
    // 0x14 str  r2,[r5,#0]     mem[0x40] = 8
    // 0x16 ldr  r6,[r5,#0]     r6 = 8
    mem[5] = {16'h682e, 16'h602a};
    // 0x18 cmp  r0,#5          sets z
    // 0x1a beq  0x1e           taken, squashes 0x1c
    mem[6] = {16'hd000, 16'h2805};
    // 0x1c movs r7,#0xff       must NOT execute
    // 0x1e movs r7,#0x11       r7 = 0x11
    mem[7] = {16'h2711, 16'h27ff};
    // ---- a real function call: prologue, body, epilogue ----
    // 0x20 bl 0x30            r14 = 0x25, branches to 0x30
    mem[8] = {16'hf806, 16'hf000};
    // 0x24 movs r1,#0x77      r1 = 0x77 once the call returns
    // 0x26 b .
    mem[9] = {16'he7fe, 16'h2177};
    mem[10] = {16'h0000, 16'h0000};
    mem[11] = {16'h0000, 16'h0000};
    // 0x30 push {r4,lr}       sp -= 8
    // 0x32 movs r4,#0x42      r4 = 0x42
    mem[12] = {16'h2442, 16'hb510};
    // 0x34 adds r4,r4,#1      r4 = 0x43
    // 0x36 pop  {r4,pc}       restores r4 = 0x42 and returns
    mem[13] = {16'hbd10, 16'h1c64};

    repeat (3) @(posedge clk);
    rst_n = 1;

    // long enough to reach the spin, short enough to notice a hang
    repeat (200) @(posedge clk);

    if (unsupported) begin
      $display("  FAIL core stopped on an unimplemented instruction at pc %08x",
               dut.e_pc);
      errs = errs + 1;
    end

    chk("r0", dut.regs[0],  32'd5);
    chk("r2", dut.regs[2],  32'd8);
    chk("r3", dut.regs[3],  32'd2);
    chk("r5", dut.regs[5],  32'h40);
    chk("r6", dut.regs[6],  32'd8);
    chk("r7", dut.regs[7],  32'h11);
    // the call ran, pushed and popped r4, and returned to 0x24
    chk("r1", dut.regs[1],  32'h77);
    // r4 is callee saved: push/pop must restore the caller's 20, not leave
    // the 0x43 the function computed
    chk("r4", dut.regs[4],  32'd20);
    chk("lr", dut.regs[14], 32'h25);
    chk("mem", mem[16],   32'd8);
    chk("sp", dut.sp_main, 32'h100);

    $display("     %0d instructions in %0d cycles, CPI %0d.%02d",
             retired, cycles, cycles / retired,
             ((cycles * 100) / retired) % 100);

    if (errs == 0) begin
      $display("ok   forwarding, memory and branch all correct");
      $display("PASS");
    end else begin
      $display("FAIL, %0d errors", errs);
    end
    $finish;
  end

  initial begin
    #100000;
    $display("FAIL timeout");
    $finish;
  end

endmodule

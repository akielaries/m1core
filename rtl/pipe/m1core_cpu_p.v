`default_nettype none

// m1core, 3-stage pipeline
//
// F  m1core_fetch, one 32-bit access per cycle, halfword queue
// D  decode table, register read, operand select, forwarding
// E  one shared datapath, branch resolve, memory, writeback
//
// port compatible with the multi-cycle m1core_cpu so it can drop into
// m1core_mcu once it is complete. this phase implements the reset sequence,
// the data-processing groups, branches and load/store. LDM/STM, exceptions,
// debug and the 32-bit forms raise d_esc and are not handled yet: the core
// stops on them so a test shows exactly where it ran out of core.
//
// ---- why there is no separate load-use interlock ----
// a memory instruction occupies E for two cycles, address phase then data
// phase, and the pipeline holds behind it. the dependent instruction sits in D
// for both, so the only hazard left is that it would latch its operands at the
// end of the data phase, before the load's non-blocking write to the register
// file lands. forwarding the load data covers exactly that cycle, which is why
// e_fwd_val selects it rather than the alu result when the instruction in E is
// a load.

module m1core_cpu_p (
  input  wire        clk,
  input  wire        rst_n,

  output reg         bus_req,
  output reg  [31:0] bus_addr,
  output reg         bus_write,
  output reg  [2:0]  bus_size,
  output reg  [31:0] bus_wdata,
  input  wire        bus_gnt,
  input  wire        bus_ready,
  input  wire [31:0] bus_rdata,

  // debug, not implemented in this phase
  input  wire        dbg_en,
  input  wire        sys_reset_req,
  input  wire        vc_corereset,
  input  wire        dbg_halt_req,
  input  wire        dbg_step_req,
  output wire        dbg_halted,
  output wire        dbg_halt_event,
  output reg         dbg_bkpt_hit,
  output wire        dbg_lockup,

  // exceptions, not implemented in this phase
  input  wire        pend_valid,
  input  wire [5:0]  pend_num,
  input  wire [2:0]  pend_prio,
  output reg         exc_taken,
  output reg  [5:0]  exc_taken_num,

  input  wire        dreg_req,
  input  wire        dreg_wnr,
  input  wire [4:0]  dreg_sel,
  input  wire [31:0] dreg_wdata,
  output reg         dreg_ack,
  output reg  [31:0] dreg_rdata,

  // ---- dedicated tcm interfaces, per the cortex-m1 trm ----
  //
  // "one core Instruction Tightly-Coupled Memory (ITCM) interface to access
  // ITCM, one core Data Tightly-Coupled Memory (DTCM) interface to access
  // DTCM", and "the TCM interface does not support wait states". that is the
  // architectural difference that matters most here: on a real m1 fetch and
  // data never contend, and neither one goes through an arbiter, an address
  // decoder or an hready mux to reach memory. everything outside the tcm
  // regions still goes out on the ahb master above
  output wire        itcm_en,
  output wire [31:0] itcm_addr,
  input  wire [31:0] itcm_rdata,

  output wire        dtcm_en,
  output wire [31:0] dtcm_addr,
  output wire        dtcm_write,
  output wire [3:0]  dtcm_be,
  output wire [31:0] dtcm_wdata,
  input  wire [31:0] dtcm_rdata,

  // visible so a test can see the core gave up rather than hang
  output reg         unsupported
);

  // the trm's map: 0x00000000-0x0fffffff is itcm, 0x20000000-0x200fffff dtcm
  localparam [3:0]  ITCM_TAG = 4'h0;
  localparam [11:0] DTCM_TAG = 12'h200;

  localparam [2:0] SZ_BYTE = 3'd0;
  localparam [2:0] SZ_HALF = 3'd1;
  localparam [2:0] SZ_WORD = 3'd2;

  localparam [1:0] MEM_NONE  = 2'd0;
  localparam [1:0] MEM_LOAD  = 2'd1;
  localparam [1:0] MEM_STORE = 2'd2;

  localparam [2:0] BR_NONE   = 3'd0;
  localparam [2:0] BR_COND   = 3'd1;
  localparam [2:0] BR_UNCOND = 3'd2;
  localparam [2:0] BR_IND    = 3'd4;

  localparam [2:0] OA_RA = 3'd0, OA_RB = 3'd1, OA_RC = 3'd2,
                   OA_SP = 3'd3, OA_PC4 = 3'd4, OA_ZERO = 3'd5;
  localparam [2:0] OB_RA = 3'd0, OB_RB = 3'd1, OB_RC = 3'd2,
                   OB_IMM = 3'd3, OB_ZERO = 3'd4;
  // must match m1core_decode.v; verilog 2001 has no packages. the groups are
  // contiguous and e_rsel below relies on that: 0..3 additive, 4..9 logic,
  // 10 shift, 11 multiply, 12..18 the sign extends and byte reverses
  localparam [4:0] OP_SHIFT = 5'd10;
  localparam [4:0] OP_MUL   = 5'd11;
  localparam [4:0] OP_SXTH  = 5'd12;

  localparam [3:0] ST_RST_SP_A = 4'd0;
  localparam [3:0] ST_RST_SP_D = 4'd1;
  localparam [3:0] ST_RST_PC_A = 4'd2;
  localparam [3:0] ST_RST_PC_D = 4'd3;
  localparam [3:0] ST_RUN      = 4'd4;
  localparam [3:0] ST_SEQ_A    = 4'd5;
  localparam [3:0] ST_SEQ_D    = 4'd6;
  localparam [3:0] ST_HALTED   = 4'd7;
  // only reached by an instruction this core does not implement. that is a
  // bug rather than an architectural state, and it is visible on purpose
  localparam [3:0] ST_STOPPED  = 4'd8;
  localparam [3:0] ST_EXC_PUSH_A = 4'd9;
  localparam [3:0] ST_EXC_PUSH_D = 4'd10;
  localparam [3:0] ST_EXC_VEC_A  = 4'd11;
  localparam [3:0] ST_EXC_VEC_D  = 4'd12;
  localparam [3:0] ST_EXC_POP_A  = 4'd13;
  localparam [3:0] ST_EXC_POP_D  = 4'd14;
  localparam [3:0] ST_SEQ_INIT   = 4'd15;

  localparam [5:0] EXC_HARDFAULT  = 6'd3;
  localparam [2:0] PRIO_HARDFAULT = 3'd1;

  reg [3:0]  state;

  // ---- the register file, one array per read port ----
  //
  // gowin's lut ram is one write and one read. a file with four readers is
  // four rams, and GowinSynthesis will not replicate an inferred array by
  // itself: with a single array it printed "Extracting RAM for identifier
  // 'regs'" and then reported `SSRAM(RAM16) 0`, which is what a silent
  // fallback to flops looks like. it recognises the shape and declines the
  // mapping.
  //
  // so the replication is explicit. all four hold identical contents, written
  // together by the single write port; each read port owns one. sixteen deep
  // rather than fifteen because a ram16 is sixteen deep and r13 and r15 are
  // never read from here anyway -- the banked stack pointer and the pc are
  // muxed in around this
  // ---- the register file: one write port, asynchronous reads, no reset ----
  //
  // one array, four read ports. it was briefly four arrays, one per reader,
  // because that is the shape a distributed ram wants and arm's own m1 has its
  // register file in ram. this device cannot:
  //
  //   WARN (IF0005) : Not support distributed RAM in current device
  //
  // GW5A has block ram and nothing between that and flops, and a 16x32 file
  // with three operand reads in the same cycle is not a block ram. so the
  // replication bought nothing -- four arrays with identical contents off a
  // shared write port are provably one array and the optimiser merged them
  // straight back, which is why the register count never moved -- and it is
  // one array again.
  //
  // what did survive from that work, and what actually paid, is the shape:
  // ONE write port and four reads rather than two writes and six reads.
  // consolidating the three state-machine readers onto one port was worth
  // 17 MHz on its own. nothing but rf_w may write this array
  reg [31:0] regs [0:15];
  reg [31:0] sp_main;
  reg        n_flag, z_flag, c_flag, v_flag;
  reg        primask;

  // ---- exception state ----
  // sp is banked. handler mode always uses msp, thread mode picks with
  // control.spsel, and regs[13] is never used so every access goes through the
  // banking rather than around it
  reg [31:0] sp_process;
  reg        mode_handler;
  reg        control_spsel;
  reg [5:0]  ipsr;

  // execution priority, smaller wins, 6 means thread with nothing active. the
  // stack is 4 deep because two priority bits cannot nest deeper
  reg [2:0]  cur_prio;
  reg [2:0]  prio_stack [0:3];
  reg [2:0]  prio_sp;

  reg [2:0]  exc_cnt;
  reg [31:0] exc_frame;

  // ---- the stacking address is a register, not an expression ----
  //
  // ST_EXC_PUSH_A used to drive the bus with
  // `(sp_read - 32) + {exc_cnt, 2'b00}`, which is two 32-bit adds in series
  // starting from the stack pointer bank mux, and the address then leaves the
  // core for the fabric decode and the slave. the timing report had eighteen
  // of the twenty-five worst paths starting at sp_process and running through
  // eight lut levels of subtract, a carry chain, three levels of fabric decode
  // and two of peripheral before reaching a register.
  //
  // both adds are loop invariant or a pure increment, so neither belongs on
  // the bus. exc_addr walks the frame the way seq_addr already walks a multi
  // register transfer, and exc_base holds the value the stack pointer ends up
  // with, so the bus sees a register output and nothing else
  reg [31:0] exc_addr;
  reg [31:0] exc_base;

  // ---- doubleword alignment of the exception frame ----
  //
  // TRM 4.5: "Doubleword alignment of the stack pointer is enforced when
  // stacking commences. Bit [2] of the stack pointer is saved as bit [9] of
  // the stacked xPSR."
  //
  // so the frame pointer is (sp - 32) with bit 2 cleared, which costs a
  // further four bytes when the stack was only word aligned, and the bit that
  // says so rides in the pushed xpsr so the unstack can put it back. without
  // it a handler entered on a word aligned stack runs on a frame the aapcs
  // says is impossible, and anything in it that needs eight byte alignment --
  // a double, a long long, a memcpy that assumes it -- is on its own
  reg exc_align;
  reg [31:0] exc_ret_addr;
  reg [5:0]  exc_num;
  reg [31:0] exc_return;
  reg [2:0]  exc_new_prio;
  reg        lockup;

  // which bank sp_read selects, held in a register rather than derived.
  //
  // decode reads the stack pointer, so !mode_handler && control_spsel sat two
  // levels in front of the register file read mux on the decode path. it can
  // be a flop because everything that changes it also redirects: exception
  // entry and return both refetch, and so now does msr to control -- see
  // msr_bank. the one cycle of staleness therefore never reaches an
  // instruction that could observe it.
  //
  // ST_EXC_PUSH_D depends on that staleness rather than merely tolerating it:
  // it reads sp_read on the same cycle it sets mode_handler, and the frame
  // belongs on the stack the core is leaving, not the one it is entering
  reg         use_psp;
  wire [31:0] sp_read = use_psp ? sp_process : sp_main;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      use_psp <= 1'b0;
    end else begin
      use_psp <= !mode_handler && control_spsel;
    end
  end

  // an exception is taken at an instruction boundary when something is pending
  // at strictly higher priority than what is executing. primask masks anything
  // with a configurable priority, which is everything the nvic can present
  // registered on purpose. the nvic's priority selection feeding this, and
  // this feeding d_ready, put the whole interrupt controller in front of the
  // core's issue decision: the report showed irq_enable -> regs[] as one
  // combinational path. an exception taken a cycle later costs nothing, and
  // pend_valid is re-checked so a withdrawn request cannot be acted on
  wire exc_ready_c = pend_valid && (pend_prio < cur_prio) && !primask;

  // registered, and the reason the issue decision is short.
  //
  // exc_go used to be a term of d_ok, so the whole chain
  //   state -> d_common -> exc_ready -> !e_v -> !mem_ph -> exc_go -> d_ok
  // sat in front of every issue, and d_ready then fed the next state, which
  // fed state. ltp measured that loop at 22 levels with no datapath in it.
  //
  // exc_hold breaks it. it says only "stop issuing, an exception is coming",
  // it is a flop, and it depends on nothing decode produces. issue stops, E
  // drains on its own, and exc_go below then finds the boundary it needs
  // without ever being looked at by d_ok. the cost is one cycle of interrupt
  // latency, and pend_valid is re-checked at exc_go so a request withdrawn in
  // the meantime cannot be acted on
  reg  exc_hold;

  reg [31:0] rst_pc;


  reg halt_pending;                 // stop at the next instruction boundary
  reg stepping;
  reg [31:0] halt_pc;               // address of the instruction not yet run
  reg halted_d;

  // stopped counts as halted to the debugger. a core sitting in ST_STOPPED
  // with the debugger seeing "running" is the worst possible hardware symptom:
  // a dead board and no way to ask it why
  assign dbg_halted     = (state == ST_HALTED) || (state == ST_STOPPED);
  // pulses on the cycle the core enters halt, however it got there. the scs
  // latches c_halt from this, and without it a core that stops of its own
  // accord -- vector catch, a completed step, bkpt -- sees c_halt still clear
  // on the very next cycle and resumes immediately
  assign dbg_halt_event = (state == ST_HALTED) && !halted_d;
  assign dbg_lockup     = lockup;

  // a halt request is honoured at an instruction boundary. decode stops
  // issuing, execute drains, and the head of the fetch queue is by definition
  // the instruction that has not run yet, so its address is the resume pc
  wire want_halt = dbg_en && (dbg_halt_req || halt_pending);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      halted_d <= 1'b0;
    end else begin
      halted_d <= (state == ST_HALTED);
    end
  end

  // ================= F =================
  reg         redirect;
  reg  [31:0] redirect_pc;
  wire        f_valid, f_valid2;
  wire [15:0] f_inst;
  wire [31:0] f_pc;
  wire        f_req_i;
  wire [31:0] f_addr_i;
  reg         f_pop;
  reg         f_pop2;
  wire [15:0] f_inst2;
  wire        mem_want;

  // a fetch inside the itcm never touches the bus, so it is granted the cycle
  // it is asked for and never waits behind a data access
  wire fetch_itcm = (f_addr_i[31:28] == ITCM_TAG);
  wire f_gnt_i    = fetch_itcm ? f_req_i
                              : (bus_gnt && !mem_want && (state == ST_RUN));
  reg  fetch_src_itcm;
  wire [31:0] f_rdata_i = fetch_src_itcm ? itcm_rdata : bus_rdata;

  assign itcm_en   = f_req_i && fetch_itcm;
  assign itcm_addr = f_addr_i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exc_hold <= 1'b0;
    end else begin
      exc_hold <= (state == ST_RUN) && exc_ready_c;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fetch_src_itcm <= 1'b0;
    end else if (f_req_i && f_gnt_i) begin
      fetch_src_itcm <= fetch_itcm;
    end
  end

  m1core_fetch #(.DEPTH(8)) u_fetch (
    .clk(clk), .rst_n(rst_n),
    .redirect(redirect), .redirect_pc(redirect_pc),
    .stall((state != ST_RUN) || want_halt),
    // only a fetch that needs the bus stands aside for a data access
    .hold_off(mem_want && !fetch_itcm),
    .f_req(f_req_i), .f_addr(f_addr_i),
    .f_gnt(f_gnt_i), .f_rdata(f_rdata_i),
    .f_valid(f_valid), .f_inst(f_inst), .f_pc(f_pc), .f_pop(f_pop),
    .f_pop2(f_pop2), .f_inst2(f_inst2),
    .f_valid2(f_valid2)
  );

  // ================= D =================
  wire [3:0]  d_ra, d_rb, d_rc, d_rd;
  wire [31:0] d_imm;
  wire [2:0]  d_opa, d_opb;
  wire [4:0]  d_op;
  wire [1:0]  d_shop;
  wire        d_sh_reg, d_wb, d_fnz, d_fc, d_fv, d_legacy;
  wire [1:0]  d_mem;
  wire [2:0]  d_msize;
  wire        d_msigned, d_st_c;
  wire [2:0]  d_br;
  wire [3:0]  d_cond;
  wire [31:0] d_boff;
  wire        d_is32, d_esc;
  wire        d_link, d_multi, d_mload, d_mextra, d_mstack;
  wire [7:0]  d_mlist;
  wire [1:0]  d_sys;
  wire [7:0]  d_sysm;
  wire        d_cps, d_cps_val;

  localparam [1:0] SYS_NONE = 2'd0;
  localparam [1:0] SYS_MSR  = 2'd1;
  localparam [1:0] SYS_MRS  = 2'd2;

  m1core_decode u_dec (
    .inst(f_inst), .inst2(f_inst2),
    .d_ra(d_ra), .d_rb(d_rb), .d_rc(d_rc), .d_rd(d_rd), .d_imm(d_imm),
    .d_opa(d_opa), .d_opb(d_opb), .d_op(d_op),
    .d_shop(d_shop), .d_sh_reg(d_sh_reg),
    .d_wb(d_wb), .d_fnz(d_fnz), .d_fc(d_fc), .d_fv(d_fv),
    .d_legacy(d_legacy),
    .d_mem(d_mem), .d_msize(d_msize), .d_msigned(d_msigned), .d_st_c(d_st_c),
    .d_br(d_br), .d_cond(d_cond), .d_boff(d_boff),
    .d_is32(d_is32), .d_esc(d_esc),
    .d_link(d_link), .d_multi(d_multi), .d_mload(d_mload),
    .d_mlist(d_mlist), .d_mextra(d_mextra), .d_mstack(d_mstack),
    .d_sys(d_sys), .d_sysm(d_sysm),
    .d_cps(d_cps), .d_cps_val(d_cps_val)
  );

  // ---- E stage registers, declared early because D forwards from them ----
  reg         e_v;
  reg  [31:0] e_pc;
  reg  [4:0]  e_op;
  reg  [1:0]  e_shop;
  reg  [3:0]  e_rd;
  reg         e_wb, e_fnz, e_fc, e_fv;
  // raw register file outputs, latched unforwarded. the operand select and the
  // forwarding mux moved out of decode and into execute: decode was doing
  // queue read -> decode -> register file -> forward -> operand mux -> latch
  // in one cycle, about 20ns of it, and that was the clock
  reg  [31:0] x_a, x_b, x_c;
  reg  [3:0]  x_rb;              // the sequencer's base register
  reg         x_fa, x_fb, x_fc;
  // and the second level of bypass, which exists because the register file
  // write is a cycle late. see the W stage below
  reg         x_fa2, x_fb2, x_fc2;
  // the stack pointer is latched like any other operand rather than read live.
  // sp_read is three levels deep on its own -- mode_handler, use_psp, the bank
  // mux -- and OA_SP put all three in front of the operand mux and the whole
  // alu. it is banked state, not a wire, so it belongs behind the same
  // register and the same one-deep bypass as the register file
  reg  [31:0] x_sp;
  reg         x_st_c;
  reg  [31:0] x_imm;

  // operand selects, with the forwarding decision already folded in
  localparam [2:0] SA_A = 3'd0, SA_B = 3'd1, SA_C  = 3'd2, SA_SP   = 3'd3,
                   SA_PC4 = 3'd4, SA_W = 3'd5, SA_ZERO = 3'd6, SA_W2 = 3'd7;
  localparam [2:0] SB_A = 3'd0, SB_B = 3'd1, SB_C  = 3'd2, SB_IMM  = 3'd3,
                   SB_W = 3'd4, SB_ZERO = 3'd5, SB_W2 = 3'd6;
  localparam [1:0] SS_IMM = 2'd0, SS_RB = 2'd1, SS_W = 2'd2, SS_W2 = 2'd3;
  reg  [2:0]  x_sela, x_selb;
  reg  [1:0]  x_selsh;

  // ---- W: the register file write happens a cycle after execute ----
  //
  // the timing report had two families of path left, and both ended in the
  // register file. One came off the operand registers through the function
  // units, the other off the bus through the byte lane extract, and both then
  // went through the result mux, the write port mux and the fanout to fifteen
  // 32-bit flop banks the placer had spread across the die. About 9 ns of a
  // 13.5 ns path was that tail, and it is common to every instruction that
  // writes a register.
  //
  // so the file is written from a register instead. `w_data` already existed
  // and already took `wb_val` at the end of every execute cycle -- it is the
  // bypass source -- so the long path already ended at a flop; it just also
  // had to reach the file in the same cycle. Now it does not, and what reaches
  // the file is one flop output with one mux in front of it.
  //
  // the cost is the second bypass level below. The comment this replaces said
  // "an instruction two behind reads the register file after the write has
  // landed", which was true and is not any more: that instruction's decode
  // read now races the write. It gets `w2_data`
  reg  [31:0] w_data;            // retired last cycle, being written now
  reg  [31:0] w2_data;           // retired the cycle before that
  reg  [3:0]  w_idx;
  reg         w_en;

  // the forward decision is made in decode and carried as one bit. comparing
  // w_rd against the source index inside execute put a 4-bit compare and an
  // and-gate at the head of the longest path, ahead of the operand mux and the
  // whole alu. decode already knows what the instruction ahead of it will
  // write, so it can answer the question a cycle early.
  //
  // these three are what the store data and the sequencer's base register use.
  // the operands proper do not go through them any more, see x_sela below
  wire [31:0] fwd_a  = x_fa  ? w_data : x_fa2 ? w2_data : x_a;
  wire [31:0] fwd_b  = x_fb  ? w_data : x_fb2 ? w2_data : x_b;
  wire [31:0] fwd_c  = x_fc  ? w_data : x_fc2 ? w2_data : x_c;

  // ---- the pc arithmetic is done in decode, not here ----
  //
  // `e_pc + 4` was a 32-bit adder feeding the operand mux, and the timing
  // report charged it 3.82 ns across four levels at the head of the longest
  // path in the design: twenty-four of the twenty-five worst paths started at
  // e_pc and went straight through it. decode already adds 4 to f_pc for the
  // r15 read ports, so the aligned form is free there and a register carries
  // it across. same for pc+2, which the link register and the msr refetch want
  reg  [31:0] x_pc4a;         // (pc + 4) & ~3, for pc-relative operands
  reg  [31:0] x_pc2;          // pc + 2
  reg  [31:0] x_pc4;          // pc + 4

  // ---- one operand mux, with the bypass folded into its select ----
  //
  // the forwarding mux used to sit in front of the operand mux: two 32-bit
  // muxes in series on the way into the function units. the timing report
  // measured the pair at three lut levels and 3.69 ns, at the head of every
  // one of the twenty-five worst paths.
  //
  // they are one mux now. decode knows both where an operand comes from and
  // whether the instruction ahead of it is about to write that source, so it
  // folds the two questions into a single select and the bypass register is
  // just another input
  reg  [31:0] e_a, e_b;
  always @* begin
    case (x_sela)
      SA_A:    e_a = x_a;
      SA_B:    e_a = x_b;
      SA_C:    e_a = x_c;
      SA_SP:   e_a = x_sp;
      SA_PC4:  e_a = x_pc4a;
      SA_W:    e_a = w_data;
      SA_W2:   e_a = w2_data;
      default: e_a = 32'd0;
    endcase
    case (x_selb)
      SB_A:    e_b = x_a;
      SB_B:    e_b = x_b;
      SB_C:    e_b = x_c;
      SB_IMM:  e_b = x_imm;
      SB_W:    e_b = w_data;
      SB_W2:   e_b = w2_data;
      default: e_b = 32'd0;
    endcase
  end

  wire [31:0] e_st = x_st_c ? fwd_c : fwd_a;

  // the shift amount gets the same treatment. every register-controlled shift
  // form takes it from rm, so there are only three possibilities and the
  // select says which without a bypass mux in front of it
  reg  [7:0]  e_shamt;
  always @* begin
    case (x_selsh)
      SS_W:    e_shamt = w_data[7:0];
      SS_W2:   e_shamt = w2_data[7:0];
      SS_RB:   e_shamt = x_b[7:0];
      default: e_shamt = x_imm[7:0];
    endcase
  end
  reg  [1:0]  e_mem;
  reg  [2:0]  e_msize;
  reg         e_msigned;
  reg  [2:0]  e_br;
  reg  [3:0]  e_cond;
  reg  [31:0] e_boff;
  reg         e_link, e_is32;
  // the address after this instruction, and the value bl and blx put in r14.
  // the thumb bit is always set because armv6-m has no other state
  wire [31:0] e_next_pc = e_is32 ? x_pc4 : x_pc2;
  wire [31:0] link_val  = e_next_pc | 32'd1;
  reg  [1:0]  e_sys;
  reg  [7:0]  e_sysm;
  reg         e_cps, e_cps_val;

  // where the result comes from, decided at decode and carried as three bits.
  //
  // all seven sources meet in one mux. they used to meet in three trees in
  // series -- the alu's nineteen-way case on op, then alu/mul/mrs, then the
  // load -- and the timing report charged 7.13 ns of a 16.34 ns path to them.
  // there is no reason for any of it to be resolved late: which unit answers
  // is a property of the opcode, and the opcode was decoded a cycle ago
  localparam [2:0] RS_SUM   = 3'd0,   // the adder
                   RS_SHIFT = 3'd1,   // the funnel shifter
                   RS_LOGIC = 3'd2,   // and/orr/eor/bic/mvn/mov
                   RS_XFORM = 3'd3,   // sxt/uxt/rev
                   RS_MUL   = 3'd4,
                   RS_SYS   = 3'd5,   // mrs
                   RS_LD    = 3'd6;
  reg  [2:0]  e_rsel;

  // the op groups are contiguous, see the localparams in m1core_decode.v, so
  // which unit answers is a five-input function of d_op and not a chain of
  // range compares. flat on purpose: written as nested ternaries this sat
  // three levels behind the decoder on the decode stage's longest path
  reg  [2:0]  rsel_op;
  always @* begin
    case (d_op)
      5'd0,  5'd1, 5'd2, 5'd3:              rsel_op = RS_SUM;
      5'd4,  5'd5, 5'd6, 5'd7, 5'd8, 5'd9:  rsel_op = RS_LOGIC;
      5'd10:                                rsel_op = RS_SHIFT;
      5'd11:                                rsel_op = RS_MUL;
      default:                              rsel_op = RS_XFORM;
    endcase
  end

  // a load answers with the bus data and an mrs with a system register; a
  // store has no destination but its address comes off the adder
  wire [2:0] rsel_next = (d_mem == MEM_LOAD) ? RS_LD :
                         (d_sys == SYS_MRS)  ? RS_SYS :
                         (d_mem != MEM_NONE) ? RS_SUM : rsel_op;

  // multiply takes its own cycle. it is the one op whose result cannot come
  // out of the shared alu mux without putting a dsp block on the forwarding
  // path, which set the clock for every other instruction
  reg [31:0]  mul_q;
  reg         mul_ph;

  // ---- the shifter takes its own cycle too, for the same reason ----
  //
  // the funnel is the deepest thing in the core. the timing report put the
  // barrel, its output class mux and the result mux together at about 7.5 ns
  // of a 15.4 ns path, and every path in the top twenty-five went through
  // them, because the shifter's output is in the same result mux as the
  // adder's and that mux feeds the register file and the bypass.
  //
  // this is exactly what was already done to the multiplier, and the build
  // that did it is in the table above: 47.3 to 52.1 MHz. a shift now lands in
  // a register at the end of its first cycle and is selected from there on the
  // second, so the barrel is alone between two flops instead of sharing a
  // cycle with the operand mux, the result mux and the register file write.
  //
  // `lsls rd, rm, #0` is decoded as a mov rather than a shift, see
  // m1core_decode.v, which matters because that is how thumb-1 spells
  // `movs rd, rm` and it would otherwise pay the extra cycle constantly
  reg [31:0]  sh_q;
  reg         sh_cq;
  reg         sh_ph;

  // whether the instruction in execute is a memory op or a multiply, decided
  // at decode and carried as single bits. comparing e_op and e_mem here
  // instead put a 5-bit compare at the head of the stall network, and that
  // network gates the clock enable of every execute register
  reg         e_is_mem, e_is_mul, e_is_sh;
  reg         mem_ph;
  reg         mem_src_dtcm;

  // ---- the address is computed a cycle before it is presented ----
  //
  // a data access used to drive the bus straight out of the adder, so
  // `x_c -> operand mux -> d_addr -> arbiter -> fabric decode -> slave address
  // phase` was one cycle: 12.7 ns of it, and fourteen of the twenty-five worst
  // paths in the round eight report. It is one adder and one decode with a
  // long wire between them, so nothing local shortens it.
  //
  // a memory instruction now spends three cycles in execute instead of two:
  // compute the address into mem_addr, present it, then the data phase. That
  // splits the path into about 6 ns inside the core and 4.6 ns from a register
  // to the slave, and it takes the arbiter and the address decode off the
  // operand path rather than adding anything to it
  reg         mem_ag;              // the address is latched, ask for the bus
  reg         mem_bad;             // ...and it was unaligned, so fault instead
  reg  [31:0] mem_addr;

  // ---- escapes are resolved in execute, not in decode ----
  //
  // ldm, stm, push, pop, svc, udf, bkpt and everything unimplemented. decode
  // used to answer "is this an escape, and which kind" and the answer gated
  // issue, so d_esc -- seven levels of priority mux inside the decoder, behind
  // the queue read -- sat in front of e_v and the state register, and the
  // instruction halfword itself was compared against 0xdf/0xde/0xbe there too.
  //
  // an escape issues into execute like anything else and is answered from
  // these flops one cycle later. it retires nothing, because e_esc holds
  // e_busy and every writeback is gated on !e_busy, so the only thing it does
  // is choose the next state. that takes the whole decoder out of the issue
  // decision, which is the loop the clock was stuck behind
  reg         e_esc, e_multi, e_mload, e_mextra, e_mstack;
  reg  [7:0]  e_mlist;
  reg  [7:0]  e_ihi;              // inst[15:8], to tell svc/udf/bkpt apart

  // observation only, so the existing testbenches can watch this core by the
  // same names they use for the multi-cycle one. the pipeline has no single
  // architectural pc, so this is the address of whatever is in execute
  wire [31:0] pc   = e_pc;
  wire [15:0] inst = f_inst;

  // multi register transfer sequencer state
  reg  [7:0]  seq_list;
  reg         seq_load, seq_extra, seq_stack, seq_wb;
  reg  [3:0]  seq_base;
  reg  [31:0] seq_addr, seq_wbval;
  reg         seq_doing_extra;
  // true on the cycle the extra (pc) word of a pop lands and it is an
  // EXC_RETURN. it feeds `redirect`, which is one bit and has always been
  // driven from this compare, and it feeds the flop below. it must NOT feed
  // `state`: bus_rdata arrives late from the fabric, and putting a 28-bit
  // compare on it in front of the state register cost a path
  //
  //   u_itcm/mem_0/DO[0] -> u_core/state_3/D
  //
  // straight into the worst 25. the decision is taken one cycle later instead,
  // from the flop, which is what seq_pop_exc was for in the first place
  wire        seq_ret_now = seq_load && seq_doing_extra && mode_handler &&
                            (bus_rdata[31:4] == 28'hfffffff);
  // set on the cycle above, read on the next one. it was originally a flop set
  // and tested in the SAME ST_SEQ_D cycle, which is non-blocking and so always
  // read the stale zero: the handover never happened, `pop {rN, pc}` fell
  // through to ST_RUN with no redirect and ran twice, and the stack drifted up
  // one pop per exception. seq_ret_ph is the extra cycle that makes the flop
  // readable
  reg         seq_pop_exc;
  reg         seq_ret_ph;
  // the base register value, latched on entry. computing the start address and
  // the writeback value straight from vb put a 32-bit adder on the end of the
  // alu-result-to-forwarding-mux path, which was the critical path: e_shop ->
  // alu -> vb -> 32-bit add -> seq_wbval. a multi register transfer already
  // spends two cycles per register, so it can afford one to do that add from a
  // register instead
  reg  [31:0] seq_vb;

  // the register the sequencer is transferring, resolved one cycle ahead.
  // lowest_set is a priority encoder and it was being evaluated combinationally
  // into the register file address, which ltp put at the head of the longest
  // path. the sequencer has cycles to spare, so it carries the answer instead
  reg [3:0] seq_low;

  // an indirect branch in flight: target captured, decision made next cycle
  reg         ind_pending;
  reg  [31:0] ind_target;

  function automatic [3:0] lowest_set(input [7:0] v);
    begin
      if      (v[0]) lowest_set = 4'd0;
      else if (v[1]) lowest_set = 4'd1;
      else if (v[2]) lowest_set = 4'd2;
      else if (v[3]) lowest_set = 4'd3;
      else if (v[4]) lowest_set = 4'd4;
      else if (v[5]) lowest_set = 4'd5;
      else if (v[6]) lowest_set = 4'd6;
      else           lowest_set = 4'd7;
    end
  endfunction

  function automatic [3:0] popcount8(input [7:0] v);
    begin
      popcount8 = {3'd0, v[0]} + {3'd0, v[1]} + {3'd0, v[2]} + {3'd0, v[3]} +
                  {3'd0, v[4]} + {3'd0, v[5]} + {3'd0, v[6]} + {3'd0, v[7]};
    end
  endfunction

  // four function units in parallel, no result mux inside. the core picks one
  // of these and one of mul_q, sysval and ld_val in a single mux, see wb_val
  wire [31:0] sum_res, sh_res, logic_res, xform_res;
  wire        sum_c, sum_v, sh_c;

  m1core_alu u_alu (
    .op(e_op), .shop(e_shop), .a(e_a), .b(e_b), .shamt(e_shamt), .cin(c_flag),
    .sum_res(sum_res), .sum_c(sum_c), .sum_v(sum_v),
    .sh_res(sh_res),   .sh_c(sh_c),
    .logic_res(logic_res), .xform_res(xform_res)
  );

  // the carry comes from the adder or the shifter and from nowhere else, and
  // the overflow only from the adder. every other op leaves both flags alone,
  // so d_fc and d_fv are clear for them and what these carry is never written
  wire alu_c = (e_rsel == RS_SHIFT) ? sh_cq : sum_c;
  wire alu_v = sum_v;

  // load data extraction, from the byte lane the slave returned it in.
  //
  // the lane is latched in the address phase, not recomputed in the data
  // phase. it is the bottom of the address, so deriving it live put the
  // forwarding mux, the operand mux and the low end of the address adder in
  // front of the load byte select -- five levels ahead of data that has only
  // just arrived on the bus, on the path into the register file. the address
  // phase already knew it a cycle earlier
  reg  [1:0]  ld_lane;
  wire [31:0] mem_rdata = mem_src_dtcm ? dtcm_rdata : bus_rdata;
  reg  [31:0] ld_val;
  always @* begin
    case (e_msize)
      SZ_BYTE: begin
        case (ld_lane)
          2'd0: ld_val = {24'd0, mem_rdata[7:0]};
          2'd1: ld_val = {24'd0, mem_rdata[15:8]};
          2'd2: ld_val = {24'd0, mem_rdata[23:16]};
          default: ld_val = {24'd0, mem_rdata[31:24]};
        endcase
        if (e_msigned) begin
          ld_val = {{24{ld_val[7]}}, ld_val[7:0]};
        end
      end
      SZ_HALF: begin
        ld_val = ld_lane[1] ? {16'd0, mem_rdata[31:16]} : {16'd0, mem_rdata[15:0]};
        if (e_msigned) begin
          ld_val = {{16{ld_val[15]}}, ld_val[15:0]};
        end
      end
      default: ld_val = mem_rdata;
    endcase
  end

  // a data access inside the dtcm goes out on its own port: no arbitration, no
  // address decode, no hready, and it cannot be delayed by an instruction fetch
  wire [31:0] d_addr   = e_a + e_b;
  // the dtcm data port is defined and wired but not used yet. a core write
  // port into the dtcm array makes two byte-enabled writers, which gowin will
  // not infer as block ram (IF0008, mem falls back to flops and blows the
  // device). the fetch port is the one that matters anyway: with fetch off the
  // bus, data has the ahb master to itself and never waits for an instruction
  wire        data_dtcm = 1'b0;

  wire is_mul   = e_v && e_is_mul;
  wire is_sh    = e_v && e_is_sh;
  // the dtcm answers in exactly one cycle, so its data phase needs no ready
  wire mem_data = mem_ph && (mem_src_dtcm || bus_ready);
  // deliberately no state test, for the same reason d_ready has none: every
  // consumer is either inside the ST_RUN arm of the case or gated on the state
  // itself, and testing it here closed the loop state -> e_busy -> d_ready ->
  // next state -> state
  wire e_busy   = e_v &&
                  ((e_is_mem && !mem_data) || (e_is_mul && !mul_ph) ||
                   (e_is_sh && !sh_ph) || e_esc);
  // armv6-m has no unaligned access support at all: a word access must be word
  // aligned and a halfword access halfword aligned. the srams mask the address
  // rather than complaining, so without this a misaligned pointer silently
  // reads the wrong location. the multi cycle core checks this in ST_MEM_A and
  // the pipeline had no equivalent
  //
  // checked off the registered address rather than off the adder, so it is two
  // bits of a flop into one compare, and it costs mem_want a single and level
  // decided off the adder's low two bits, which are the fastest bits it has,
  // and registered into mem_bad. NOT tested in mem_want: mem_want drives
  // bus_req out to the fabric, and an and level there showed up as
  // state -> u_fabric/sel_q/D and state -> u_gpio/a_off/CE in the worst 25.
  // this way mem_want is bit for bit what it was before the check existed
  wire mem_misalign = ((e_msize == SZ_WORD) && (d_addr[1:0] != 2'b00)) ||
                      ((e_msize == SZ_HALF) && d_addr[0]);

  // the address-generate cycle, and then the address phase
  wire mem_new    = (state == ST_RUN) && e_v && e_is_mem && !mem_ag && !mem_ph &&
                    !mem_bad;
  wire mem_fault  = (state == ST_RUN) && mem_bad;
  assign mem_want = (state == ST_RUN) && e_v && e_is_mem && mem_ag && !mem_ph;

  // byte lanes for a dtcm write, the same replication the ahb slaves expect
  reg [3:0] dtcm_be_r;
  always @* begin
    case (e_msize)
      SZ_BYTE: dtcm_be_r = 4'b0001 << mem_addr[1:0];
      SZ_HALF: dtcm_be_r = mem_addr[1] ? 4'b1100 : 4'b0011;
      default: dtcm_be_r = 4'b1111;
    endcase
  end

  assign dtcm_en    = mem_want && data_dtcm;
  assign dtcm_addr  = mem_addr;
  assign dtcm_write = (e_mem == MEM_STORE);
  assign dtcm_be    = (e_mem == MEM_STORE) ? dtcm_be_r : 4'b0000;
  assign dtcm_wdata = (e_msize == SZ_BYTE) ? {4{e_st[7:0]}} :
                      (e_msize == SZ_HALF) ? {2{e_st[15:0]}} : e_st;

  // mrs reads a system register rather than the datapath. there is no ipsr,
  // psp or control on this core yet, so those read as zero
  reg [31:0] sysval;
  always @* begin
    case (e_sysm)
      8'd0, 8'd1, 8'd2, 8'd3:
               sysval = {n_flag, z_flag, c_flag, v_flag, 22'd0, ipsr};
      8'd5:    sysval = {26'd0, ipsr};
      8'd8:    sysval = sp_main;
      8'd9:    sysval = sp_process;
      8'd16:   sysval = {31'd0, primask};
      8'd20:   sysval = {30'd0, control_spsel, 1'b0};
      default: sysval = 32'd0;
    endcase
  end

  // ---- one flat result mux ----
  //
  // there used to be three in series: alu/mul/mrs into e_result, then load
  // into wb_val, then the msr alignment into sp_wdata. that is three mux
  // levels bolted onto the end of the alu, on the path that ends at the
  // register file and the stack pointer.
  //
  // the seven sources are mutually exclusive and which one applies is known at
  // decode, so the select is a register and the mux is one level. e_result is
  // gone: everything that used it -- flags, the forwarding register, the
  // indirect branch target -- wanted the same value, because an instruction
  // that loads sets no flags and does not write r15
  wire wb_now  = (state == ST_RUN) && e_v && !e_busy;
  wire wb_any  = wb_now && (((e_mem == MEM_NONE) && e_wb && (e_rd != 4'd15)) ||
                            (e_mem == MEM_LOAD));
  wire wb_sp   = wb_any && (e_rd == 4'd13);
  wire wb_reg  = wb_any && (e_rd != 4'd13);

  // whether the instruction in execute writes what the one in decode reads.
  // this is the whole of the forwarding decision and it is made here, a cycle
  // before the value is needed
  // bl and blx write r14 with a return address rather than a datapath result.
  // they are mutually exclusive with a normal writeback -- neither sets d_wb --
  // so they can share the W stage instead of needing a port of their own
  wire link_now = wb_now && e_link;

  wire fwd_hit_a  = wb_any && (e_rd == d_ra);
  wire fwd_hit_b  = wb_any && (e_rd == d_rb);
  wire fwd_hit_c  = wb_any && (e_rd == d_rc);
  wire fwd_hit_sp = wb_sp;

  // and the same question one instruction further back. the register file
  // write is a cycle late, so the write landing at the end of this cycle is
  // the one decode's read has just missed. its value is in w_data now and in
  // w2_data next cycle, which is when the instruction being latched wants it.
  //
  // the stack pointer needs no equivalent: sp_main and sp_process are two
  // registers rather than fifteen banks, so their write was never on a long
  // path and was left where it was
  wire w_hit_a = w_en && (w_idx == d_ra);
  wire w_hit_b = w_en && (w_idx == d_rb);
  wire w_hit_c = w_en && (w_idx == d_rc);


  // ---- the datapath result, with the load left out ----
  //
  // the same seven-way mux as wb_val minus the load. no armv6-m load sets
  // flags, and none can write the stack pointer either -- every load form
  // takes its destination from inst[2:0] or inst[10:8], so it is r0 to r7.
  //
  // that is not an optimisation of a don't-care. the load is the one source
  // that arrives from the bus, so sharing a mux with it hands the static
  // timing analyser a chain from a peripheral's address register into the
  // flags and into the stack pointer that software cannot exercise. both
  // showed up: z_flag in one report, and sp_process in the next, the latter as
  // the worst inbound path in the design
  reg [31:0] dp_val;
  always @* begin
    case (e_rsel)
      RS_SHIFT: dp_val = sh_q;
      RS_LOGIC: dp_val = logic_res;
      RS_XFORM: dp_val = xform_res;
      RS_MUL:   dp_val = mul_q;
      RS_SYS:   dp_val = sysval;
      default:  dp_val = sum_res;       // RS_SUM, and RS_LD which writes neither
    endcase
  end

  wire res_zero = (dp_val == 32'd0);

  // the load meets one mux, not the wide one.
  //
  // dp_val below is the same seven-way select without the load in it, and the
  // load is the source that arrives last -- off the bus, through the byte lane
  // extract. putting it in the wide mux made it pay for the width: the itcm
  // read path measured seven lut levels from the fabric to here. it needs a
  // two to one against everything else instead, and dp_val is already built
  wire [31:0] wb_val = (e_rsel == RS_LD) ? ld_val : dp_val;

  // msr to msp and psp writes a stack pointer from the datapath, exactly like
  // a writeback does, so it goes through the same one mux. reaching sp_main
  // from inside the state case, then `if (e_v && !e_busy)`, then
  // `if (e_mem == MEM_NONE)`, then `if (e_sys == SYS_MSR)`, then `case
  // (e_sysm)` was seven mux levels hanging off the datapath result, and it was
  // the longest path in the core once the issue loop was broken
  wire msr_ok  = wb_now && (e_mem == MEM_NONE) && (e_sys == SYS_MSR);
  wire msr_msp = msr_ok && (e_sysm == 8'd8);
  wire msr_psp = msr_ok && (e_sysm == 8'd9);

  wire        sp_wr    = wb_sp || msr_msp || msr_psp;

  // primask and control.spsel, flat for the same reason everything else here
  // is. `msr primask, rn` reached its flop through the state case, then
  // `if (e_v && !e_busy)`, then `if (e_mem == MEM_NONE)`, then
  // `if (e_sys == SYS_MSR)`, then `case (e_sysm)` -- four levels of mux
  // hanging off the datapath result, and it showed up as a family of worst
  // paths ending at primask. cps reaches primask the same way and is folded in
  wire msr_pri  = msr_ok && (e_sysm == 8'd16);
  // control is only writable from thread mode
  wire msr_ctl  = msr_ok && (e_sysm == 8'd20) && !mode_handler;
  wire cps_now  = wb_now && (e_mem == MEM_NONE) && e_cps;

  wire pri_we   = msr_pri || cps_now;
  wire pri_val  = cps_now ? e_cps_val : wb_val[0];
  wire        sp_wpsp  = msr_ok ? msr_psp : use_psp;
  // dp_val, not wb_val: see above, no load can write the stack pointer, and
  // taking the value from the mux that includes one put the inbound bus path
  // in front of these flops. an msr decodes as a mov, so dp_val is already the
  // value being written and the alignment is two bits of mask on an existing
  // wire rather than another mux
  wire [31:0] sp_wdata = msr_ok ? {dp_val[31:2], 2'b00} : dp_val;


  wire [31:0] pc4       = f_pc + 32'd4;
  wire [31:0] pc2       = f_pc + 32'd2;

  // read ports are written out rather than wrapped in a function on purpose.
  // a function that reads regs, e_rd and e_fwd_val from inside a continuous
  // assignment does not reliably re-evaluate when the array changes, which
  // showed up as operands going stale for three cycles and forwarding never
  // happening at all. indexing the array directly in the assign is both
  // correct and the shape synthesis expects of a register file read port
  wire [31:0] raw_a = (d_ra == 4'd13) ? sp_read :
                      (d_ra == 4'd15) ? pc4 : regs[d_ra];
  wire [31:0] raw_b = (d_rb == 4'd13) ? sp_read :
                      (d_rb == 4'd15) ? pc4 : regs[d_rb];
  wire [31:0] raw_c = (d_rc == 4'd13) ? sp_read :
                      (d_rc == 4'd15) ? pc4 : regs[d_rc];

  // no forwarding here any more: decode just reads. the bypass is in execute,
  // and the sequencer takes its base register from the bypassed value too


  // an instruction can enter E when one is available, the pipeline is not held
  // behind a memory access, and it is something this phase implements
  // redirect is registered, so for one cycle after a taken branch the queue
  // still holds the wrong-path halfwords it fetched speculatively. decode must
  // not act on them: literal pools sit immediately after branches, and
  // 0xffffffff decodes as an unimplemented instruction, while anything that
  // happens to decode as a valid one would simply execute off the wrong path
  // exc_go and d_ok share most of their terms and were each rebuilding them as
  // a serial and chain, with d_ok then waiting on the whole of exc_go. ltp put
  // this loop -- state -> exc_go -> d_ready -> next state -- at 20 levels with
  // no datapath in it at all, which is why nothing done to the alu moved it
  // deliberately no state test. d_ready is only ever used inside the ST_RUN
  // arm of the case, so testing state here is redundant -- and it was what
  // closed the feedback loop that ltp measured at 20 levels: state -> d_common
  // -> exc_go -> d_ready -> next state -> state. f_pop, the one consumer
  // outside the case, is gated on the state itself instead
  wire d_common = f_valid && !redirect && !want_halt;
  // exc_hold, not exc_go. see where it is declared: this is the term that used
  // to close the loop, and it is now a flop
  wire exc_go   = exc_hold && pend_valid && d_common && !e_v && !mem_ph;
  // e_busy is the late signal here: it comes off mem_ph/bus_ready and fans out
  // to everything decode gates. the other six terms settle early, so they are
  // grouped first and e_busy joins through a single gate rather than sitting in
  // the middle of a seven-deep and chain
  wire d_ok    = d_common && !exc_hold && !ind_pending &&
                 (!d_is32 || f_valid2);
  wire d_ready = d_ok && !e_busy;
  // an escape issues like anything else now, so there is no !d_esc here and
  // the decoder's priority chain is off this path entirely
  wire d_go    = d_ready;

  // ================= branch resolve =================
  reg cond_ok;
  always @* begin
    case (e_cond)
      4'h0: cond_ok = z_flag;
      4'h1: cond_ok = !z_flag;
      4'h2: cond_ok = c_flag;
      4'h3: cond_ok = !c_flag;
      4'h4: cond_ok = n_flag;
      4'h5: cond_ok = !n_flag;
      4'h6: cond_ok = v_flag;
      4'h7: cond_ok = !v_flag;
      4'h8: cond_ok = c_flag && !z_flag;
      4'h9: cond_ok = !c_flag || z_flag;
      4'ha: cond_ok = (n_flag == v_flag);
      4'hb: cond_ok = (n_flag != v_flag);
      4'hc: cond_ok = !z_flag && (n_flag == v_flag);
      4'hd: cond_ok = z_flag || (n_flag != v_flag);
      default: cond_ok = 1'b1;
    endcase
  end

  // a write to r15 is a branch, which is how bx, blx, mov pc,rm and add pc,rm
  // all reduce to one case
  // ---- branch resolution, split by where the target comes from ----
  //
  // a direct branch's target is e_pc + 4 + offset and owes nothing to the alu,
  // so it redirects in the same cycle. an indirect one -- bx, pop {pc}, any
  // write to r15, an exception return -- takes its target from the datapath
  // result, and routing that through the EXC_RETURN compare and into the clock
  // enable of redirect_pc and exc_frame was the critical path on 14 of the 25
  // worst: e_op -> result mux -> 28-bit compare -> enable of 64 flops.
  //
  // indirect branches instead register the result and act on it the next
  // cycle. they are the minority, and one cycle on a function return buys the
  // alu out of the redirect enable network entirely
  wire br_dir_taken = e_v && !e_busy &&
                      ((e_br == BR_UNCOND) || ((e_br == BR_COND) && cond_ok));
  wire br_ind_req   = e_v && !e_busy &&
                      ((e_br == BR_IND) || (e_wb && (e_rd == 4'd15)));
  wire br_taken     = br_dir_taken || br_ind_req;
  // x_pc4, not e_pc + 4. decode already adds four to the same value for the
  // r15 read ports and carries it across, and writing the sum out here made
  // the tool build the increment in logic ahead of the carry chain: the
  // timing report showed nine lut levels between e_pc and this adder, on six
  // of the twenty-five worst paths. this is one add of two registers
  wire [31:0] br_target = x_pc4 + e_boff;

  // ---- msr to a stack pointer or to control refetches ----
  //
  // decode reads the register file and the stack pointer a cycle before
  // execute uses them, so the instruction sitting in decode behind an
  // `msr control, rn` has already sampled the wrong bank, and behind an
  // `msr msp, rn` the wrong value. armv6-m requires an isb after writing
  // control for exactly this reason and does not promise anything otherwise,
  // but a core that quietly runs on the wrong stack is not worth the cycles
  // saved. these are startup and context-switch instructions; squashing decode
  // and refetching costs a few cycles somewhere that already costs hundreds
  wire msr_bank = wb_now && (e_mem == MEM_NONE) && (e_sys == SYS_MSR) &&
                  ((e_sysm == 8'd8) || (e_sysm == 8'd9) || (e_sysm == 8'd20));

  // ================= bus =================
  //
  // a case on state, not a chain of else-ifs testing it. the chain built seven
  // muxes in series on every one of bus_req, bus_addr, bus_size and wdata_sel,
  // and bus_req is the clock enable of bus_wdata, so state -> mem_want ->
  // hold_off -> f_req -> seven muxes -> 32 flops was the longest path in the
  // core. the arms are mutually exclusive, so a case gives one balanced mux
  reg        rst_req;
  reg [31:0] rst_addr;
  reg [31:0] wdata_sel;

  // ---- the ST_RUN arm, built separately so the state mux stays flat ----
  //
  // three cases: a data access starting, a wait-stated one holding the bus, or
  // the fetch. the middle one exists because ahb requires address and control
  // held while hready is low, and because ahb_fabric latches the data-phase
  // owner from htrans: a fetch address issued during a wait-stated apb read
  // moves hready to the itcm, which is always ready, and the core then samples
  // the previous cycle's rdata instead of the read it is waiting for
  wire        run_hold = mem_ph && !bus_ready;
  wire        run_mem  = mem_want && !data_dtcm;
  wire        run_req  = run_mem || (!run_hold && f_req_i);
  wire [31:0] run_addr = run_mem ? mem_addr : f_addr_i;
  wire        run_wr   = run_mem && (e_mem == MEM_STORE);
  wire [2:0]  run_size = run_mem ? e_msize : SZ_WORD;
  // replicate a byte or halfword across the bus. the slave picks the lane from
  // the address and size, so the value has to be present in whichever lane it
  // selects rather than only in the low one
  wire [31:0] run_wdata = (e_msize == SZ_BYTE) ? {4{e_st[7:0]}} :
                          (e_msize == SZ_HALF) ? {2{e_st[15:0]}} : e_st;

  // the exception frame is r0-r3, r12, lr, pc, xpsr in that order
  wire [3:0] pop_idx = (exc_cnt == 3'd4) ? 4'd12 :
                       (exc_cnt == 3'd5) ? 4'd14 : {1'b0, exc_cnt};

  // ---- one read port for everything outside the pipeline ----
  //
  // the file had six read structures on it: the three operand ports, the
  // exception frame, the multi register transfer, and the debugger. each one
  // is a fifteen way 32-bit mux wired to all 480 flops, and the result is a
  // block every part of the design connects to, which is a placement problem
  // rather than a depth problem -- the report has the datapath spread over
  // twenty rows with 73% of the path in routing.
  //
  // the last three are in mutually exclusive states, so they take turns on one
  // mux instead of building three. the operand ports stay as they are: they
  // are the ones that need to be fast
  reg [3:0] rf_s_idx;
  always @* begin
    case (state)
      // the frame is r0-r3, r12, lr, and pop_idx already spells that
      ST_EXC_PUSH_A: rf_s_idx = pop_idx;
      ST_SEQ_A:      rf_s_idx = seq_doing_extra ? 4'd14 : seq_low;
      default:       rf_s_idx = dreg_sel[3:0];
    endcase
  end

  wire [31:0] rf_s_dat = regs[rf_s_idx];

  reg [31:0] push_word;
  always @* begin
    case (exc_cnt)
      3'd6: push_word = exc_ret_addr;
      // xpsr. bit 24 is the thumb bit and is always set on armv6-m
      // xpsr. bit 24 is the thumb bit and is always set on armv6-m; bit 9 is
      // the frame alignment the unstack has to undo
      3'd7: push_word = {n_flag, z_flag, c_flag, v_flag, 3'd0, 1'b1,
                         14'd0, exc_align, 3'd0, ipsr};
      default: push_word = rf_s_dat;
    endcase
  end

  wire [31:0] seq_word = (!seq_doing_extra && (seq_low == 4'd13)) ? sp_main
                                                                 : rf_s_dat;

  always @* begin
    case (state)
      ST_EXC_PUSH_A: begin
        bus_req   = 1'b1;
        bus_addr  = exc_addr;
        bus_write = 1'b1;
        bus_size  = SZ_WORD;
        wdata_sel = push_word;
      end
      ST_EXC_VEC_A: begin
        // no vtor on armv6-m, the table is fixed at zero
        bus_req   = 1'b1;
        bus_addr  = {24'd0, exc_num, 2'b00};
        bus_write = 1'b0;
        bus_size  = SZ_WORD;
        wdata_sel = 32'd0;
      end
      ST_EXC_POP_A: begin
        bus_req   = 1'b1;
        bus_addr  = exc_addr;
        bus_write = 1'b0;
        bus_size  = SZ_WORD;
        wdata_sel = 32'd0;
      end
      ST_SEQ_A: begin
        bus_req   = 1'b1;
        bus_addr  = seq_addr;
        bus_write = !seq_load;
        bus_size  = SZ_WORD;
        wdata_sel = seq_word;
      end
      ST_RUN: begin
        bus_req   = run_req;
        bus_addr  = run_addr;
        bus_write = run_wr;
        bus_size  = run_size;
        wdata_sel = run_wdata;
      end
      default: begin
        bus_req   = rst_req;
        bus_addr  = rst_addr;
        bus_write = 1'b0;
        bus_size  = SZ_WORD;
        wdata_sel = 32'd0;
      end
    endcase
  end

  // ================= register file and stack pointer write ports =============
  //
  // the file had eight write ports and the stack pointer seven, one per place
  // in the state machine that wrote them, because verilog infers a port per
  // distinct index expression and a mux level per nested condition. that is
  // why a word arriving on the bus reached regs[] fourteen levels later: the
  // load data had to climb back out through every one of them.
  //
  // there are two register ports and one stack pointer port below, each one
  // flat: an enable, an index and a value, selected by state. two register
  // ports rather than one because a multi register transfer writes a loaded
  // register and the base register writeback in the same cycle

  // the last word of a multi register transfer, whichever way it ends
  wire [7:0] seq_rest = seq_list & ~(8'd1 << seq_low);
  wire       seq_last = seq_doing_extra ||
                        (!seq_extra && (seq_rest == 8'd0));
  wire       seq_base_wb = seq_last && seq_wb && !seq_stack &&
                           (seq_base != 4'd13);
  wire       seq_wb_now  = (state == ST_SEQ_D) && bus_ready && seq_base_wb;

  wire       dreg_go  = dreg_req && !dreg_ack;
  wire       dreg_wr  = dreg_go && dreg_wnr;


  reg         rf_w_en;
  reg  [3:0]  rf_w_idx;
  reg  [31:0] rf_w_dat;
  always @* begin
    // the pipeline's own writeback comes from the W register and takes the
    // port whenever it has something, whatever the state is -- the last
    // instruction to retire before an escape or an exception still has a write
    // to land, one cycle after the state has already moved on.
    //
    // nothing else can want the port in that cycle. the sequencer's first
    // write is three cycles after the escape that starts it, exception entry
    // needs an empty execute stage to happen at all, and the core drains
    // before it halts
    rf_w_en  = w_en;
    rf_w_idx = w_idx;
    rf_w_dat = w_data;
    case (state)
      ST_SEQ_D: begin
        rf_w_en  = bus_ready && seq_load && !seq_doing_extra &&
                   (seq_low != 4'd13);
        rf_w_idx = seq_low;
        rf_w_dat = bus_rdata;
      end
      ST_EXC_POP_D: begin
        rf_w_en  = bus_ready && (exc_cnt <= 3'd5);
        rf_w_idx = pop_idx;
        rf_w_dat = bus_rdata;
      end
      ST_HALTED: begin
        rf_w_en  = dreg_wr && (dreg_sel <= 5'd14) && (dreg_sel != 5'd13);
        rf_w_idx = dreg_sel[3:0];
        rf_w_dat = dreg_wdata;
      end
      ST_EXC_PUSH_D: begin
        // the EXC_RETURN value the handler will `bx lr` on. w_en is long since
        // clear by here -- wb_reg requires ST_RUN and this is sixteen bus
        // transactions later -- so the port is free
        rf_w_en  = bus_ready && (exc_cnt == 3'd7);
        rf_w_idx = 4'd14;
        rf_w_dat = mode_handler ? 32'hffff_fff1 :
                   (control_spsel ? 32'hffff_fffd : 32'hffff_fff9);
      end
      default: begin
      end
    endcase
  end

  // ---- the flags, one write port ----
  //
  // n and z end the longest path in the core: the zero detect is a 32 input
  // reduction sitting behind the result mux, and it then had to climb back out
  // through `if (e_v && !e_busy)`, `if (e_mem == MEM_NONE)`, `if (e_fnz)` and
  // the state case to reach the flop. flat, that tail is one mux
  wire msr_apsr = msr_ok && (e_sysm <= 8'd3);
  wire run_fnz  = wb_now && (e_mem == MEM_NONE) && e_fnz;
  wire run_fc   = wb_now && (e_mem == MEM_NONE) && e_fc;
  wire run_fv   = wb_now && (e_mem == MEM_NONE) && e_fv;

  reg  flg_we_n, flg_we_z, flg_we_c, flg_we_v;
  reg  flg_n, flg_z, flg_c, flg_v;
  always @* begin
    flg_we_n = 1'b0;
    flg_we_z = 1'b0;
    flg_we_c = 1'b0;
    flg_we_v = 1'b0;
    // n and z come off wb_val and res_zero, which cover the multiply too: muls
    // sets them from the product, and the product does not come out of the alu.
    // c and v are the adder's and the shifter's, and no armv6-m multiply or
    // logic op touches either
    // an msr decodes as a mov, so dp_val is its operand
    flg_n = dp_val[31];
    flg_z = msr_apsr ? dp_val[30] : res_zero;
    flg_c = msr_apsr ? dp_val[29] : alu_c;
    flg_v = msr_apsr ? dp_val[28] : alu_v;
    case (state)
      ST_RUN: begin
        flg_we_n = run_fnz || msr_apsr;
        flg_we_z = run_fnz || msr_apsr;
        flg_we_c = run_fc  || msr_apsr;
        flg_we_v = run_fv  || msr_apsr;
      end
      ST_HALTED: begin
        flg_we_n = dreg_wr && (dreg_sel == 5'd16);
        flg_we_z = flg_we_n;
        flg_we_c = flg_we_n;
        flg_we_v = flg_we_n;
        {flg_n, flg_z, flg_c, flg_v} = dreg_wdata[31:28];
      end
      ST_EXC_POP_D: begin
        flg_we_n = bus_ready && (exc_cnt == 3'd7);
        flg_we_z = flg_we_n;
        flg_we_c = flg_we_n;
        flg_we_v = flg_we_n;
        {flg_n, flg_z, flg_c, flg_v} = bus_rdata[31:28];
      end
      default: begin
      end
    endcase
  end

  // the stack pointer, banked. handler mode always uses msp, thread mode picks
  // with control.spsel, and regs[13] is never used so every access goes
  // through the banking rather than around it
  reg         spw_en;
  reg         spw_psp;
  reg  [31:0] spw_dat;
  // note that ST_RUN is not one of these. the pipeline's own writeback has its
  // own port below, because it is the only one whose data comes off the
  // datapath: sharing this mux made the stack pointer pay for six arms and
  // measured five lut levels and 3.8 ns hanging off the adder, which was the
  // longest path in the core. the others all come from a register or the bus
  always @* begin
    spw_en  = 1'b0;
    spw_psp = 1'b0;
    spw_dat = bus_rdata & 32'hffff_fffc;
    case (state)
      ST_RST_SP_D: begin
        spw_en = bus_ready;
      end
      ST_SEQ_D: begin
        spw_en  = bus_ready && seq_last && seq_wb && seq_stack;
        spw_psp = 1'b0;
        spw_dat = seq_wbval;
      end
      ST_HALTED: begin
        spw_en  = dreg_wr && ((dreg_sel == 5'd13) || (dreg_sel == 5'd17));
        spw_psp = 1'b0;
        spw_dat = dreg_wdata;
      end
      ST_EXC_PUSH_D: begin
        spw_en  = bus_ready && (exc_cnt == 3'd7);
        spw_psp = use_psp;
        spw_dat = exc_base;
      end
      ST_EXC_POP_D: begin
        // exc_return[2] selects the stack returned to. bus_rdata is the popped
        // xpsr in this cycle, and its bit 9 says whether entry inserted four
        // bytes of padding to reach doubleword alignment
        spw_en  = bus_ready && (exc_cnt == 3'd7);
        spw_psp = exc_return[2];
        spw_dat = (exc_frame + 32'd32) | (bus_rdata[9] ? 32'd4 : 32'd0);
      end
      default: begin
      end
    endcase
  end

  // ahb presents write data in the data phase, one cycle after the address
  // phase it belongs to, and ahb_arb routes it combinationally from the
  // master. by then this core's bus mux has moved on to the next access, so
  // the data has to be registered at grant or every store writes zero
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bus_wdata <= 32'd0;
    end else if (bus_req && bus_gnt) begin
      bus_wdata <= wdata_sel;
    end
  end

  always @* begin
    f_pop  = (state == ST_RUN) && d_go && !br_taken && !msr_bank;
    f_pop2 = d_is32;
  end

  // ---- the register file: one write port, asynchronous reads, no reset ----
  //
  // this shape is the point. a synchronous single write port with
  // asynchronous reads and no reset is what a distributed ram wants, and it is
  // what arm's own m1 uses -- `reg_file_b_..._RAMREG` turns up in its timing
  // report where ours had fifteen banks of flops. as flops it was 480
  // registers with two write ports and six read muxes, a block that every part
  // of the design connects to, and the placer answered by spreading the
  // datapath over twenty rows with 73% of the critical path in routing.
  //
  // getting here took three things: the state machine's reads share one port
  // because they are in mutually exclusive states; the sequencer's base
  // writeback and bl's link write ride the W stage instead of holding a second
  // write port open; and there is no reset, because the armv6-m general
  // registers are UNKNOWN out of reset and a ram cannot have one anyway.
  //
  // nothing but rf_w may write this array. adding a second writer anywhere
  // silently turns it back into flops
  //
  // the reset is here on purpose. armv6-m leaves the general registers UNKNOWN
  // out of reset and a ram cannot have one, so it was removed while the file
  // was being shaped for a distributed ram. that shape is unreachable on this
  // device -- Version A has 0K of S-SRAM, see the bugs list -- and without the
  // reset the array starts as X in simulation, which propagates: a register
  // read before it is written reaches the flags, then cond_ok, then br_taken,
  // then e_v, and an X in e_v stalls execute forever because e_busy feeds back
  // into it. `make excp` hung at a pc that depended on code layout, which is
  // what X sensitivity looks like from the outside.
  //
  // gowin flops come up at zero from configuration anyway, so this costs
  // nothing real and buys a deterministic simulation
  integer kr;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (kr = 0; kr < 16; kr = kr + 1) begin
        regs[kr] <= 32'd0;
      end
    end else if (rf_w_en) begin
      regs[rf_w_idx] <= rf_w_dat;
    end
  end

  integer k;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= ST_RST_SP_A;
      e_v         <= 1'b0;
      mem_ph      <= 1'b0;
      mem_ag      <= 1'b0;
      mem_bad     <= 1'b0;
      seq_ret_ph  <= 1'b0;
      seq_pop_exc <= 1'b0;
      redirect    <= 1'b0;
      redirect_pc <= 32'd0;
      rst_req     <= 1'b0;
      rst_addr    <= 32'd0;
      sp_main     <= 32'd0;
      rst_pc      <= 32'd0;
      n_flag      <= 1'b0;
      z_flag      <= 1'b0;
      c_flag      <= 1'b0;
      v_flag      <= 1'b0;
      primask     <= 1'b0;
      e_sys       <= SYS_NONE;
      unsupported <= 1'b0;
      halt_pending  <= 1'b0;
      stepping      <= 1'b0;
      halt_pc       <= 32'd0;
      dbg_bkpt_hit  <= 1'b0;
      exc_taken     <= 1'b0;
      exc_taken_num <= 6'd0;
      dreg_ack      <= 1'b0;
      dreg_rdata    <= 32'd0;
      sp_process    <= 32'd0;
      mode_handler  <= 1'b0;
      control_spsel <= 1'b0;
      ipsr          <= 6'd0;
      cur_prio      <= 3'd6;
      prio_sp       <= 3'd0;
      lockup        <= 1'b0;
      exc_cnt       <= 3'd0;
      exc_num       <= 6'd0;
      exc_return    <= 32'd0;
      exc_frame     <= 32'd0;
      exc_addr      <= 32'd0;
      exc_base      <= 32'd0;
      exc_align     <= 1'b0;
      exc_ret_addr  <= 32'd0;
      exc_new_prio  <= 3'd6;
      e_cps         <= 1'b0;
      mul_ph        <= 1'b0;
      mul_q         <= 32'd0;
      sh_ph         <= 1'b0;
      sh_q          <= 32'd0;
      sh_cq         <= 1'b0;
      mem_src_dtcm  <= 1'b0;
      ld_lane       <= 2'd0;
      mem_ag        <= 1'b0;
      mem_addr      <= 32'd0;
      seq_vb        <= 32'd0;
      seq_low       <= 4'd0;
      w_data        <= 32'd0;
      w2_data       <= 32'd0;
      w_idx         <= 4'd0;
      w_en          <= 1'b0;
      x_fa          <= 1'b0;
      x_fa2         <= 1'b0;
      x_fb2         <= 1'b0;
      x_fc2         <= 1'b0;
      x_fb          <= 1'b0;
      x_fc          <= 1'b0;
      x_sela        <= SA_ZERO;
      x_selb        <= SB_ZERO;
      x_selsh       <= SS_IMM;
      x_sp          <= 32'd0;
      x_pc4a        <= 32'd0;
      x_pc2         <= 32'd0;
      x_pc4         <= 32'd0;
      x_st_c        <= 1'b0;
      ind_pending   <= 1'b0;
      ind_target    <= 32'd0;
      e_is_mem      <= 1'b0;
      e_is_mul      <= 1'b0;
      e_is_sh       <= 1'b0;
      e_rsel        <= RS_SUM;
      e_esc         <= 1'b0;
      e_multi       <= 1'b0;
      e_mload       <= 1'b0;
      e_mextra      <= 1'b0;
      e_mstack      <= 1'b0;
      e_mlist       <= 8'd0;
      e_ihi         <= 8'd0;
      for (k = 0; k < 4; k = k + 1) begin
        prio_stack[k] <= 3'd6;
      end
    end else if (sys_reset_req) begin
      // aircr.sysresetreq from the debugger. with no nrst wired this is the
      // only reset path gdb has, and without it a load leaves the core at a
      // stale pc with a stale sp, so resuming runs the old image
      state       <= ST_RST_SP_A;
      e_v         <= 1'b0;
      mem_ph      <= 1'b0;
      mem_ag      <= 1'b0;
      redirect    <= 1'b0;
      rst_req     <= 1'b0;
      dreg_ack    <= 1'b0;
      halt_pending<= 1'b0;
      stepping    <= 1'b0;
      unsupported <= 1'b0;
      n_flag      <= 1'b0;
      z_flag      <= 1'b0;
      c_flag      <= 1'b0;
      v_flag      <= 1'b0;
      primask     <= 1'b0;
      e_sys       <= SYS_NONE;
      mode_handler  <= 1'b0;
      control_spsel <= 1'b0;
      ipsr          <= 6'd0;
      cur_prio      <= 3'd6;
      prio_sp       <= 3'd0;
      lockup        <= 1'b0;
      exc_cnt       <= 3'd0;
      exc_taken     <= 1'b0;
    end else begin
      redirect  <= 1'b0;
      exc_taken <= 1'b0;
      dreg_ack <= 1'b0;

      case (state)
        // ---- the vector table: sp from 0, pc from 4 ----
        ST_RST_SP_A: begin
          rst_req  <= 1'b1;
          rst_addr <= 32'd0;
          if (bus_gnt) begin
            rst_req <= 1'b0;
            state   <= ST_RST_SP_D;
          end
        end
        ST_RST_SP_D: begin
          if (bus_ready) begin
            // sp_main is written by the stack pointer port
            rst_req  <= 1'b1;
            rst_addr <= 32'd4;
            state    <= ST_RST_PC_A;
          end
        end
        ST_RST_PC_A: begin
          if (bus_gnt) begin
            rst_req <= 1'b0;
            state   <= ST_RST_PC_D;
          end
        end
        ST_RST_PC_D: begin
          if (bus_ready) begin
            rst_pc  <= bus_rdata & 32'hffff_fffe;
            halt_pc <= bus_rdata & 32'hffff_fffe;
            if (dbg_en && vc_corereset) begin
              // vector catch: stop at the reset handler without executing it,
              // which is how gdb gets control of a freshly reset core
              state <= ST_HALTED;
            end else begin
              redirect    <= 1'b1;
              redirect_pc <= bus_rdata & 32'hffff_fffe;
              state       <= ST_RUN;
            end
          end
        end

        ST_RUN: begin
          // ---- E: complete whatever is there ----
          if (e_v && !e_busy) begin
            // bl and blx write r14 through the W stage, see link_now
            if (e_mem == MEM_NONE) begin
              // the register and sp writeback is hoisted out of this case, see
              // below: routing e_result through the state mux and five nested
              // conditions to reach sp_main was seven levels of the path
              // cps, msr to primask and msr to control are the write ports
              // at the bottom of this block. apsr is the flag port, and msp
              // and psp are the stack pointer port
            end
          end

          // multiply sub-phase: capture the product, use it next cycle
          if (is_mul && !mul_ph) begin
            mul_q  <= e_a * e_b;
            mul_ph <= 1'b1;
          end else if (mul_ph) begin
            mul_ph <= 1'b0;
          end

          // shift sub-phase: capture the shifted value, use it next cycle
          if (is_sh && !sh_ph) begin
            sh_q   <= sh_res;
            sh_cq  <= sh_c;
            sh_ph  <= 1'b1;
          end else if (sh_ph) begin
            sh_ph <= 1'b0;
          end

          // memory sub-phase
          // address generate: the adder's output goes to a register, not to
          // the bus. the byte lane comes with it, it is the bottom of the
          // same value
          if (mem_new) begin
            mem_ag   <= !mem_misalign;
            mem_bad  <=  mem_misalign;
            mem_addr <= d_addr;
            ld_lane  <= d_addr[1:0];
          end

          if (mem_want && (data_dtcm || bus_gnt)) begin
            mem_ph       <= 1'b1;
            mem_ag       <= 1'b0;
            mem_src_dtcm <= data_dtcm;
          end else if (mem_data) begin
            mem_ph <= 1'b0;
          end

          // capture what execute wrote, for the next instruction to bypass.
          // only updated when execute actually advances: the operands are now
          // combinational off this register, so clearing it under a memory or
          // multiply instruction that occupies execute for two cycles would
          // change that instruction's own address halfway through

          // ---- direct branch: target is known without the alu ----
          if (br_dir_taken) begin
            redirect    <= 1'b1;
            redirect_pc <= br_target;
          end

          // ---- msr to a stack pointer or control: refetch, see above ----
          if (msr_bank) begin
            redirect    <= 1'b1;
            redirect_pc <= e_next_pc;
          end

          // ---- indirect branch: capture the target, decide next cycle ----
          if (br_ind_req) begin
            ind_pending <= 1'b1;
            ind_target  <= wb_val;
          end

          if (ind_pending) begin
            ind_pending <= 1'b0;
            // in handler mode an EXC_RETURN magic value here is an exception
            // return rather than a branch, which is how a c handler gets back
            if (mode_handler && (ind_target[31:4] == 28'hfffffff)) begin
              exc_return <= ind_target;
              exc_frame  <= ind_target[2] ? sp_process : sp_main;
              exc_addr   <= ind_target[2] ? sp_process : sp_main;
              exc_cnt    <= 3'd0;
              state      <= ST_EXC_POP_A;
            end else begin
              redirect    <= 1'b1;
              redirect_pc <= ind_target & 32'hffff_fffe;
            end
          end

          // an exception is taken at an instruction boundary, which for this
          // pipeline means execute is empty and nothing is in flight. the
          // instruction still sitting at the head of the fetch queue is the
          // one that has not run, so its address is the return address
          if (exc_go) begin
            exc_num      <= pend_num;
            exc_ret_addr <= f_pc;
            exc_new_prio <= pend_prio;
            exc_cnt      <= 3'd0;
            exc_addr     <= (sp_read - 32'd32) & ~32'd4;
            exc_base     <= (sp_read - 32'd32) & ~32'd4;
            exc_align    <= sp_read[2];
            state        <= ST_EXC_PUSH_A;
            e_v          <= 1'b0;
          end

          // one instruction retired is a completed step
          if (stepping && e_v && !e_busy) begin
            stepping     <= 1'b0;
            halt_pending <= 1'b1;
          end

          // the pipeline is drained and the queue head is the next instruction
          if (want_halt && !e_v && !mem_ph && f_valid && !redirect) begin
            halt_pc      <= f_pc;
            halt_pending <= 1'b0;
            state        <= ST_HALTED;
          end

          // ---- E: an instruction the pipeline does not run itself ----
          //
          // every condition here is a flop. the escape was resolved in decode
          // before, which put the decoder's priority chain and three compares
          // against the raw halfword in front of the state register
          if (e_v && e_esc) begin
            e_v <= 1'b0;
            // gdb reads this back to say where the core stopped, and it is the
            // resume address: the escape has been popped from the queue, so a
            // redirect to it is what re-runs the instruction
            halt_pc <= e_pc;
            if (e_multi) begin
              // the sequencer owns the bus and the register file while it
              // runs, and e_v above is what guarantees nothing is left in E
              seq_list        <= e_mlist;
              seq_load        <= e_mload;
              seq_extra       <= e_mextra;
              seq_stack       <= e_mstack;
              seq_base        <= x_rb;
              seq_doing_extra <= 1'b0;
              // armv6-m LDM: `wback = (registers<n> == '0')`. if the base
              // register is itself in the list it takes the loaded value and
              // the writeback does not happen. we wrote back unconditionally,
              // so `ldmia r0!, {r0, r1}` clobbered the word it had just
              // loaded. stm always writes back, and push/pop reach the stack
              // pointer through its own port rather than this one
              seq_wb          <= !(e_mload && !e_mstack &&
                                   e_mlist[x_rb[2:0]]);
              // only latch operands here; the arithmetic happens next cycle.
              // the forwarded value, not the raw one: the base register may
              // have been written by the instruction immediately before
              seq_vb          <= fwd_b;
              state           <= ST_SEQ_INIT;
            end else if (e_ihi == 8'hdf) begin
              // svc is synchronous: taken here rather than routed through the
              // nvic, and it returns to the instruction after it
              exc_num      <= 6'd11;
              exc_ret_addr <= e_pc + 32'd2;
              exc_new_prio <= 3'd2;
              exc_cnt      <= 3'd0;
              exc_addr     <= (sp_read - 32'd32) & ~32'd4;
              exc_base     <= (sp_read - 32'd32) & ~32'd4;
              exc_align    <= sp_read[2];
              state        <= ST_EXC_PUSH_A;
            end else if (e_ihi == 8'hde) begin
              // permanently undefined. a real part takes a hardfault so a
              // handler can report it, rather than stopping dead
              exc_num      <= EXC_HARDFAULT;
              exc_ret_addr <= e_pc;
              exc_new_prio <= PRIO_HARDFAULT;
              exc_cnt      <= 3'd0;
              exc_addr     <= (sp_read - 32'd32) & ~32'd4;
              exc_base     <= (sp_read - 32'd32) & ~32'd4;
              exc_align    <= sp_read[2];
              state        <= ST_EXC_PUSH_A;
            end else if (dbg_en) begin
              // bkpt, which is how gdb sets a software breakpoint, and
              // anything this core does not implement
              dbg_bkpt_hit <= (e_ihi == 8'hbe);
              unsupported  <= (e_ihi != 8'hbe);
              state        <= ST_HALTED;
            end else begin
              // with no debugger attached there is nothing to resume this, and
              // halting would just livelock on the same instruction
              unsupported <= 1'b1;
              state       <= ST_STOPPED;
            end
          end

          // ---- E: an unaligned load or store ----
          //
          // it never reaches a data phase, so mem_data stays low and e_busy
          // stays high: e_v has to be cleared here the way the escape path
          // above does it, or execute never empties
          if (mem_fault) begin
            e_v          <= 1'b0;
            mem_ag       <= 1'b0;
            mem_bad      <= 1'b0;
            exc_num      <= EXC_HARDFAULT;
            exc_ret_addr <= e_pc;
            exc_new_prio <= PRIO_HARDFAULT;
            exc_cnt      <= 3'd0;
            exc_addr     <= (sp_read - 32'd32) & ~32'd4;
            exc_base     <= (sp_read - 32'd32) & ~32'd4;
            exc_align    <= sp_read[2];
            state        <= ST_EXC_PUSH_A;
          end

          // ---- D to E ----
          if (!e_busy) begin
            // a taken branch squashes decode. so does exc_ret_go, which
            // redirects the pipeline just as surely: without it a handler's
            // `bx lr` is followed by the padding nop and then whatever the
            // literal pool decodes as. so does a stack pointer or control
            // write, which is a redirect for the same reason a branch is: what
            // decode already sampled is no longer true
            e_v <= d_go && !br_taken && !msr_bank;

            // the datapath registers load unconditionally whenever execute is
            // free. loading them with a decode that will not issue is
            // harmless, because e_v above is what says the contents mean
            // anything, and it keeps d_go -- and with it the whole
            // combinational decoder -- off the clock enable of these ~200
            // flops. that enable network was the critical path
            e_pc      <= f_pc;
            e_op      <= d_op;
            e_shop    <= d_shop;
            e_rd      <= d_rd;
            e_wb      <= d_wb;
            e_fnz     <= d_fnz;
            e_fc      <= d_fc;
            e_fv      <= d_fv;
            x_a       <= raw_a;
            x_b       <= raw_b;
            x_c       <= raw_c;
            x_rb      <= d_rb;
            // what execute is about to retire is what the writeback register
            // will hold next cycle, so the comparison belongs here
            x_fa      <= fwd_hit_a;
            x_fb      <= fwd_hit_b;
            x_fc      <= fwd_hit_c;
            x_fa2     <= w_hit_a && !fwd_hit_a;
            x_fb2     <= w_hit_b && !fwd_hit_b;
            x_fc2     <= w_hit_c && !fwd_hit_c;
            x_sp      <= sp_read;
            // the pc arithmetic, done here so execute has none
            x_pc4a    <= {pc4[31:2], 2'b00};
            x_pc2     <= pc2;
            x_pc4     <= pc4;
            // where each operand comes from, with the bypass folded in, so
            // execute selects once instead of forwarding and then selecting
            // the newer write wins: fwd_hit is the instruction retiring this
            // cycle, w_hit the one that retired last cycle
            x_sela    <= (d_opa == OA_RA)  ? (fwd_hit_a  ? SA_W :
                                              w_hit_a    ? SA_W2 : SA_A)  :
                         (d_opa == OA_RB)  ? (fwd_hit_b  ? SA_W :
                                              w_hit_b    ? SA_W2 : SA_B)  :
                         (d_opa == OA_RC)  ? (fwd_hit_c  ? SA_W :
                                              w_hit_c    ? SA_W2 : SA_C)  :
                         (d_opa == OA_SP)  ? (fwd_hit_sp ? SA_W : SA_SP)  :
                         (d_opa == OA_PC4) ? SA_PC4 : SA_ZERO;
            x_selb    <= (d_opb == OB_RA)  ? (fwd_hit_a ? SB_W :
                                              w_hit_a   ? SB_W2 : SB_A) :
                         (d_opb == OB_RB)  ? (fwd_hit_b ? SB_W :
                                              w_hit_b   ? SB_W2 : SB_B) :
                         (d_opb == OB_RC)  ? (fwd_hit_c ? SB_W :
                                              w_hit_c   ? SB_W2 : SB_C) :
                         (d_opb == OB_IMM) ? SB_IMM : SB_ZERO;
            x_selsh   <= !d_sh_reg ? SS_IMM :
                         fwd_hit_b ? SS_W : w_hit_b ? SS_W2 : SS_RB;
            x_imm     <= d_imm;
            x_st_c    <= d_st_c;
            e_mem     <= d_mem;
            e_msize   <= d_msize;
            e_msigned <= d_msigned;
            e_br      <= d_br;
            e_cond    <= d_cond;
            e_boff    <= d_boff;
            e_link    <= d_link;
            e_is32    <= d_is32;
            e_sys     <= d_sys;
            e_sysm    <= d_sysm;
            e_cps     <= d_cps;
            e_cps_val <= d_cps_val;
            e_is_mem  <= (d_mem != MEM_NONE);
            e_is_mul  <= (d_op == OP_MUL) && (d_mem == MEM_NONE);
            e_is_sh   <= (d_op == OP_SHIFT) && (d_mem == MEM_NONE);
            // which function unit answers, worked out here so that execute
            // only has to select
            e_rsel    <= rsel_next;
            e_esc     <= d_esc;
            e_multi   <= d_multi;
            e_mload   <= d_mload;
            e_mextra  <= d_mextra;
            e_mstack  <= d_mstack;
            e_mlist   <= d_mlist;
            e_ihi     <= f_inst[15:8];
          end
        end

        // one cycle to work out where the block starts and where the base
        // register ends up, from values that are already registered
        ST_SEQ_INIT: begin
          if (seq_stack) begin
            if (seq_load) begin
              // pop: read upward from sp
              seq_addr  <= sp_read;
              seq_wbval <= sp_read +
                {26'd0, (popcount8(seq_list) + {3'd0, seq_extra}), 2'b00};
            end else begin
              // push: the block sits below sp and is written upward
              seq_addr  <= sp_read -
                {26'd0, (popcount8(seq_list) + {3'd0, seq_extra}), 2'b00};
              seq_wbval <= sp_read -
                {26'd0, (popcount8(seq_list) + {3'd0, seq_extra}), 2'b00};
            end
          end else begin
            seq_addr  <= seq_vb;
            seq_wbval <= seq_vb + {26'd0, popcount8(seq_list), 2'b00};
          end
          seq_low <= lowest_set(seq_list);
          state   <= ST_SEQ_A;
        end

        // ---- multi register transfer ----
        // one word per iteration, lowest numbered register at the lowest
        // address, which is the order the architecture specifies for both
        // directions and both the stack and the ldmia/stmia forms
        ST_SEQ_A: begin
          if (bus_gnt) begin
            state <= ST_SEQ_D;
          end
        end

        ST_SEQ_D: begin
          if (seq_ret_ph) begin
            // the decision cycle. flops only
            seq_ret_ph <= 1'b0;
            if (seq_pop_exc) begin
              seq_pop_exc <= 1'b0;
              exc_cnt     <= 3'd0;
              state       <= ST_EXC_POP_A;
            end else begin
              state <= ST_RUN;
            end
          end else if (bus_ready) begin
            if (seq_load) begin
              if (seq_doing_extra) begin
                // pop pc. in handler mode an EXC_RETURN magic value here is an
                // exception return, not a branch: `pop {r4, pc}` is how a c
                // handler that pushed lr gets back, and it is just as valid a
                // return as `bx lr`
                // the three data registers load unconditionally and only the
                // one-bit controls are gated. the EXC_RETURN test is a 28-bit
                // compare on data that has just come off the bus, and putting
                // it in the clock enable of redirect_pc, exc_return and
                // exc_frame drove ninety-six flops from it: six of the
                // twenty-five worst paths ended at a redirect_pc CE pin. this
                // is the same mistake the indirect branch path already had,
                // recorded below, in the one place it was not fixed.
                //
                // loading them when the value is not an EXC_RETURN is harmless.
                // redirect_pc is only read when redirect is set, and exc_return,
                // exc_frame and exc_addr are only read in ST_EXC_POP_*, which is
                // only reached through seq_pop_exc
                //
                // exc_addr belongs in this group and was briefly not in it. it
                // was loaded under `if (seq_pop_exc)` below, which put the
                // 28-bit compare on its clock enable, and sixteen of the
                // twenty-five worst paths in the build that followed ran
                // u_itcm/mem_2/DO[0] -> exc_addr_*/CE. that is the same mistake
                // this comment was written about, made again two lines away
                // from where it is written
                exc_return  <= bus_rdata;
                // the frame sits above this pop, so it is at the stack pointer
                // this sequencer is about to write back, not the one it still
                // has. taking sp_main here puts the frame one whole pop too low
                // and unstacks garbage
                exc_frame   <= bus_rdata[2] ? sp_process : seq_wbval;
                exc_addr    <= bus_rdata[2] ? sp_process : seq_wbval;
                redirect_pc <= bus_rdata & 32'hffff_fffe;
                seq_pop_exc <= seq_ret_now;
                if (!seq_ret_now) begin
                  redirect <= 1'b1;
                end
              end
              // the loaded register itself is written by rf_w
            end

            seq_addr <= seq_addr + 32'd4;

            if (seq_doing_extra) begin
              // that was the last one. the base register writeback goes
              // through the W stage, see seq_wb_now; the stack form of it is
              // the stack pointer port.
              //
              // linger here one cycle rather than deciding now. deciding now
              // means the compare reaches the state register; deciding next
              // cycle reads a flop. ST_SEQ_D drives no bus request -- it falls
              // to the default arm of the bus mux -- so the extra cycle is idle
              seq_ret_ph <= 1'b1;
            end else begin
              seq_list <= seq_rest;
              seq_low  <= lowest_set(seq_rest);
              if (seq_rest == 8'd0) begin
                if (seq_extra) begin
                  seq_doing_extra <= 1'b1;
                  state           <= ST_SEQ_A;
                end else begin
                  // the writeback is the two ports above, gated on seq_last
                  state <= ST_RUN;
                end
              end else begin
                state <= ST_SEQ_A;
              end
            end
          end
        end

        ST_HALTED: begin
          e_v <= 1'b0;
          if (dreg_req && !dreg_ack) begin
            dreg_ack <= 1'b1;
            if (dreg_wnr) begin
              // the general registers and the stack pointer are the write
              // ports above; only the odd ones are left here
              case (dreg_sel)
                5'd15:   halt_pc <= dreg_wdata & 32'hffff_fffe;
                // 16, the flags, is the flag write port
                5'd20:   primask <= dreg_wdata[0];
                default: begin
                end
              endcase
            end else begin
              case (dreg_sel)
                5'd15:   dreg_rdata <= halt_pc;
                5'd16:   dreg_rdata <= {n_flag, z_flag, c_flag, v_flag, 28'd0};
                5'd13,
                5'd17:   dreg_rdata <= sp_main;
                5'd20:   dreg_rdata <= {31'd0, primask};
                default: dreg_rdata <= (dreg_sel <= 5'd14) ? rf_s_dat : 32'd0;
              endcase
            end
          // halted_d gates the resume by a cycle so the scs has time to latch
          // c_halt. without it the core sees c_halt still clear and runs one
          // instruction past the halt point
          end else if (halted_d && (!dbg_en || !dbg_halt_req)) begin
            dbg_bkpt_hit <= 1'b0;
            stepping     <= dbg_en && dbg_step_req;
            redirect     <= 1'b1;
            redirect_pc  <= halt_pc;
            state        <= ST_RUN;
          end
        end

        // ---- exception entry: stack 8 words, then fetch the vector ----
        ST_EXC_PUSH_A: begin
          // a fault while already at hardfault priority has nowhere to
          // escalate to. real hardware calls this lockup; stopping leaves the
          // debugger something to look at
          if (exc_num == EXC_HARDFAULT && cur_prio <= PRIO_HARDFAULT) begin
            lockup <= 1'b1;
            state  <= ST_STOPPED;
          end else if (bus_gnt) begin
            state <= ST_EXC_PUSH_D;
          end
        end

        ST_EXC_PUSH_D: begin
          if (bus_ready) begin
            if (exc_cnt == 3'd7) begin
              // the frame is written, now switch into handler mode. the new
              // stack pointer and the EXC_RETURN value in r14 are the write
              // ports above
              prio_stack[prio_sp[1:0]] <= cur_prio;
              prio_sp       <= prio_sp + 3'd1;
              cur_prio      <= exc_new_prio;
              mode_handler  <= 1'b1;
              ipsr          <= exc_num;
              exc_taken     <= 1'b1;
              exc_taken_num <= exc_num;
              exc_cnt       <= 3'd0;
              state         <= ST_EXC_VEC_A;
            end else begin
              exc_cnt  <= exc_cnt + 3'd1;
              exc_addr <= exc_addr + 32'd4;
              state    <= ST_EXC_PUSH_A;
            end
          end
        end

        ST_EXC_VEC_A: begin
          if (bus_gnt) begin
            state <= ST_EXC_VEC_D;
          end
        end

        ST_EXC_VEC_D: begin
          if (bus_ready) begin
            redirect    <= 1'b1;
            redirect_pc <= bus_rdata & 32'hffff_fffe;
            state       <= ST_RUN;
          end
        end

        // ---- exception return: unstack the same 8 words ----
        ST_EXC_POP_A: begin
          if (bus_gnt) begin
            state <= ST_EXC_POP_D;
          end
        end

        ST_EXC_POP_D: begin
          if (bus_ready) begin
            // the frame is r0-r3, r12, lr, pc, xpsr in that order
            if (exc_cnt <= 3'd5) begin
              // the register itself is written by rf_w, indexed by pop_idx
              exc_cnt  <= exc_cnt + 3'd1;
              exc_addr <= exc_addr + 32'd4;
              state    <= ST_EXC_POP_A;
            end else if (exc_cnt == 3'd6) begin
              redirect_pc <= bus_rdata & 32'hffff_fffe;
              exc_cnt     <= exc_cnt + 3'd1;
              exc_addr    <= exc_addr + 32'd4;
              state       <= ST_EXC_POP_A;
            end else begin
              // the flags are the flag write port
              ipsr <= bus_rdata[5:0];
              // exc_return[3] selects the mode returned to, [2] the stack
              mode_handler  <= !exc_return[3];
              control_spsel <= exc_return[3] ? exc_return[2] : 1'b0;
              // the restored stack pointer is the write port above
              if (prio_sp != 3'd0) begin
                cur_prio <= prio_stack[prio_sp[1:0] - 3'd1];
                prio_sp  <= prio_sp - 3'd1;
              end else begin
                cur_prio <= 3'd6;
              end
              exc_cnt  <= 3'd0;
              redirect <= 1'b1;
              state    <= ST_RUN;
            end
          end
        end

        ST_STOPPED: begin
          e_v <= 1'b0;
          // a debugger attaching after the fact can still find out where and
          // why, which is the whole point of recording halt_pc on the way in
          if (dbg_en) begin
            state <= ST_HALTED;
          end
        end

        default: begin
          e_v <= 1'b0;
        end
      endcase

      // ---- the write ports, outside the state machine on purpose ----
      //
      // this is the only place the register file and the stack pointers are
      // written. every value reaching them passes one mux, not the state case
      // plus however many nested ifs the state in question happened to use.
      //
      if (pri_we) begin
        primask <= pri_val;
      end
      if (msr_ctl) begin
        control_spsel <= wb_val[1];
      end

      // the pipeline's stack pointer writeback, on its own port. it and spw
      // below are mutually exclusive by state
      if (sp_wr) begin
        if (sp_wpsp) begin
          sp_process <= sp_wdata;
        end else begin
          sp_main <= sp_wdata;
        end
      end
      if (spw_en) begin
        if (spw_psp) begin
          sp_process <= spw_dat;
        end else begin
          sp_main <= spw_dat;
        end
      end
      // ---- W: the pipeline's writeback register ----
      //
      // outside the state case on purpose. wb_reg already requires ST_RUN, so
      // out here w_en clears itself the moment the core leaves it -- and it
      // has to, because rf_w below is shared with the sequencer and the
      // exception unstacker. left inside the ST_RUN arm it simply stopped
      // being updated when the state moved on, so a write that had already
      // landed stayed pending and fired again on the way back, overwriting
      // whatever the sequencer had just loaded. `make corep` caught it.
      //
      // the value shifting on while no instruction is in execute is harmless:
      // nothing selects it, because both hit bits come from wb_any and w_en,
      // and both are false outside ST_RUN
      if (!e_busy) begin
        w2_data <= w_data;
        if (seq_wb_now) begin
          // the sequencer's base register writeback. it used to be a second
          // write port, colliding with the loaded word in this very cycle,
          // and that second port is what stopped the file being one write and
          // three reads -- the shape a distributed ram wants and the shape
          // arm's own m1 uses (`reg_file_b_..._RAMREG` in its timing report).
          //
          // it rides the W stage instead and lands one cycle later, in ST_RUN
          // or ST_EXC_POP_A, where nothing else is writing. no extra state and
          // no extra cycle, and the instruction whose decode read races it
          // picks the value up through the second bypass level exactly as it
          // would from any other writeback
          w_data <= seq_wbval;
          w_idx  <= seq_base;
          w_en   <= 1'b1;
        end else begin
          // bl and blx write the return address to r14; everything else writes
          // the datapath result to its own destination. never both
          w_data <= link_now ? link_val : wb_val;
          w_idx  <= link_now ? 4'd14    : e_rd;
          w_en   <= link_now || wb_reg;
        end
      end

      if (flg_we_n) begin
        n_flag <= flg_n;
      end
      if (flg_we_z) begin
        z_flag <= flg_z;
      end
      if (flg_we_c) begin
        c_flag <= flg_c;
      end
      if (flg_we_v) begin
        v_flag <= flg_v;
      end
    end
  end

endmodule

`default_nettype wire

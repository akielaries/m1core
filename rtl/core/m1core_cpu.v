`default_nettype none

// m1core cpu: armv6-m, multi-cycle
//
// deliberately not pipelined. nothing in the toolchain or the debugger can
// observe pipeline timing, and a multi-cycle machine is far easier to get
// right. it can be pipelined later without changing the programmer's model
//
// instruction fetch is one halfword at a time. that costs cycles but removes
// every alignment special case, since a 32-bit thumb instruction is just two
// halfword fetches
//
// not implemented yet: exceptions, nvic, svc. those come with the next stage.
// bkpt and svc currently halt the core, which is at least visible in gdb

module m1core_cpu (
  input  wire        clk,
  input  wire        rst_n,

  // ahb-lite master, request/grant so it can share the bus with the debugger
  output reg         bus_req,
  output reg  [31:0] bus_addr,
  output reg         bus_write,
  output reg  [2:0]  bus_size,
  output reg  [31:0] bus_wdata,
  input  wire        bus_gnt,
  input  wire        bus_ready,
  input  wire [31:0] bus_rdata,

  // debug control from the scs
  input  wire        dbg_en,
  input  wire        sys_reset_req,
  input  wire        vc_corereset,
  input  wire        dbg_halt_req,
  input  wire        dbg_step_req,
  output wire        dbg_halted,
  // pulses when the core stops of its own accord, so the scs can set c_halt
  output wire        dbg_halt_event,
  output reg         dbg_bkpt_hit,
  output wire        dbg_lockup,

  // exception interface to the nvic
  input  wire        pend_valid,
  input  wire [5:0]  pend_num,
  input  wire [2:0]  pend_prio,
  output reg         exc_taken,
  output reg  [5:0]  exc_taken_num,

  // debug register access, only honoured while halted
  input  wire        dreg_req,
  input  wire        dreg_wnr,
  input  wire [4:0]  dreg_sel,
  input  wire [31:0] dreg_wdata,
  output reg         dreg_ack,
  output reg  [31:0] dreg_rdata
);

  localparam [2:0] SZ_BYTE = 3'd0;
  localparam [2:0] SZ_HALF = 3'd1;
  localparam [2:0] SZ_WORD = 3'd2;

  // result select, see the one result mux at the end of execute
  localparam [3:0] RES_NONE  = 4'd0;
  localparam [3:0] RES_ALU   = 4'd1;
  localparam [3:0] RES_SHIFT = 4'd2;
  // RES_IMM retired with the 8-bit immediate group, which the decode table
  // now covers. the code is left unused rather than renumbering the rest
  localparam [3:0] RES_RES   = 4'd4;
  localparam [3:0] RES_SPIMM = 4'd5;
  localparam [3:0] RES_PCIMM = 4'd6;
  localparam [3:0] RES_LR2   = 4'd7;
  localparam [3:0] RES_LR4   = 4'd8;
  localparam [3:0] RES_EXT   = 4'd9;
  localparam [3:0] RES_REV   = 4'd10;
  localparam [3:0] RES_MRS   = 4'd11;

  // decode control word encodings. these MUST match m1core_decode.v; verilog
  // 2001 has no packages, so the two lists are kept in step by hand
  localparam [2:0] OA_RA = 3'd0, OA_RB = 3'd1, OA_RC = 3'd2,
                   OA_SP = 3'd3, OA_PC4 = 3'd4, OA_ZERO = 3'd5;
  localparam [2:0] OB_RA = 3'd0, OB_RB = 3'd1, OB_RC = 3'd2,
                   OB_IMM = 3'd3, OB_ZERO = 3'd4;
  localparam [3:0] OP_ADD = 4'd0, OP_ADC = 4'd1, OP_SUB = 4'd2, OP_SBC = 4'd3,
                   OP_AND = 4'd4, OP_ORR = 4'd5, OP_EOR = 4'd6, OP_BIC = 4'd7,
                   OP_MVN = 4'd8, OP_MOV = 4'd9, OP_SHIFT = 4'd10,
                   OP_MUL = 4'd11;

  // shared shifter ops, see do_shift
  localparam [1:0] SH_LSL = 2'd0;
  localparam [1:0] SH_LSR = 2'd1;
  localparam [1:0] SH_ASR = 2'd2;
  localparam [1:0] SH_ROR = 2'd3;

  // armv6-m has no configurable faults, everything escalates to hardfault at a
  // fixed priority above anything software can set
  localparam [5:0] EXC_HARDFAULT  = 6'd3;
  localparam [2:0] PRIO_HARDFAULT = 3'd1;

  // state encoding, was a typedef enum before the verilog 2001 down-convert
  localparam [4:0] ST_RST_SP_A = 5'd0;
  localparam [4:0] ST_RST_SP_D = 5'd1;
  localparam [4:0] ST_RST_PC_A = 5'd2;
  localparam [4:0] ST_RST_PC_D = 5'd3;
  localparam [4:0] ST_HALTED = 5'd4;
  localparam [4:0] ST_FETCH_A = 5'd5;
  localparam [4:0] ST_FETCH_D = 5'd6;
  localparam [4:0] ST_FETCH2_A = 5'd7;
  localparam [4:0] ST_FETCH2_D = 5'd8;
  localparam [4:0] ST_EXEC = 5'd9;
  localparam [4:0] ST_MEM_A = 5'd10;
  localparam [4:0] ST_MEM_D = 5'd11;
  localparam [4:0] ST_MULTI_A = 5'd12;
  localparam [4:0] ST_MULTI_D = 5'd13;
  localparam [4:0] ST_EXC_PUSH_A = 5'd14;
  localparam [4:0] ST_EXC_PUSH_D = 5'd15;
  localparam [4:0] ST_EXC_VEC_A  = 5'd16;
  localparam [4:0] ST_EXC_VEC_D  = 5'd17;
  localparam [4:0] ST_EXC_POP_A  = 5'd18;
  localparam [4:0] ST_EXC_POP_D  = 5'd19;
  localparam [4:0] ST_DECODE    = 5'd20;

  reg [4:0] state;

  // r0-r12 plus r13 sp and r14 lr. pc is separate because it is written by
  // control flow rather than by the register write port
  reg [31:0] regs [0:14];
  reg [31:0] pc;
  reg        n_flag, z_flag, c_flag, v_flag;
  reg        primask;

  // the single write port, driven by wreg() and by the datapath writebacks.
  // see the one place regs is actually assigned, at the end of the state machine
  reg        wb_en;
  reg [3:0]  wb_idx;
  reg [31:0] wb_data;

  // ---- exception state ----
  // sp is banked. handler mode always uses msp; thread mode picks with
  // control.spsel. regs[13] is left unused so every sp access goes through the
  // banking, which is the whole point
  reg [31:0] sp_main;
  reg [31:0] sp_process;
  reg        mode_handler;
  reg        control_spsel;
  reg [5:0]  ipsr;

  // execution priority, smaller wins. 6 means thread, nothing active.
  // the stack is 4 deep because with two priority bits nothing can nest deeper
  reg [2:0]  cur_prio;
  reg [2:0]  prio_stack [0:3];
  reg [2:0]  prio_sp;

  reg [2:0]  exc_cnt;
  reg [31:0] exc_frame;
  reg [31:0] exc_ret_addr;
  reg [5:0]  exc_num;
  reg [31:0] exc_return;
  reg [2:0]  exc_new_prio;

  // address of the instruction currently executing. a synchronous fault stacks
  // this, not the advanced pc, so a handler can see what actually faulted
  reg [31:0] inst_pc;

  // set when a fault is taken while already at hardfault priority. real
  // hardware calls this lockup: there is nothing left to escalate to
  reg        lockup;

  wire use_psp = !mode_handler && control_spsel;
  wire [31:0] sp_read = use_psp ? sp_process : sp_main;

  // operands, read one cycle ahead of execute.
  //
  // reading early is equivalent, not merely plausible: nothing writes regs, pc
  // or sp between decode and execute, and rd() of r15 and r13 depend only on
  // those, so a cycle earlier returns the same values.
  //
  // deliberately not reset. decode always runs before execute reaches them, and
  // more 32 bit registers on the power on reset net is real fanout on a net
  // that already drives 2054 loads
  reg [31:0] r_a, r_b, r_c, sp_q;

  // an exception is taken at an instruction boundary when something is pending
  // at a strictly higher priority than what is currently executing. primask
  // masks everything with a configurable priority, which is everything the nvic
  // can present today
  wire exc_ready = pend_valid && (pend_prio < cur_prio) && !primask;

  reg [15:0] inst;
  reg [15:0] inst2;
  reg        is32;

  // three read ports, not seven.
  //
  // the first version of this stage read all candidate slots in parallel so
  // that execute never had to know the instruction format. that is a lot of
  // register file: each slot is its own 16 to 1 mux over r0-r12 plus the pc and
  // sp special cases, and the file is the widest structure in the core.
  //
  // no armv6-m instruction reads more than three registers, so three ports is
  // the real requirement, and the candidate fields collapse onto them almost
  // for free: every port a variant is {x, inst[2:0]} and every port b variant
  // is {x, inst[5:3]}, differing only in the top bit. only port c has to pick
  // between two different 3-bit fields.
  //
  // the selects cost a 4-bit mux each and sit in decode, where there is slack,
  // rather than in execute, where the critical path is
  wire [3:0] a_idx = (inst[15:11] == 5'b11110)  ? inst[3:0] :            // msr
                     (inst[15:10] == 6'b010001) ? {inst[7], inst[2:0]} : // high
                                                  {1'b0, inst[2:0]};
  wire [3:0] b_idx = (inst[15:10] == 6'b010001) ? inst[6:3] :            // high
                                                  {1'b0, inst[5:3]};
  // the 8-bit immediate group and the sp-relative loads and stores name their
  // register in inst[10:8]; everything else that reads a third register uses
  // inst[8:6]
  wire [3:0] c_idx = ((inst[15:13] == 3'b001) || (inst[15:12] == 4'b1001))
                     ? {1'b0, inst[10:8]} : {1'b0, inst[8:6]};

  // pending memory operation
  reg [3:0]  ld_rd;
  reg        ld_signed;
  reg        ld_is_load;
  reg [2:0]  ld_size;
  reg [1:0]  ld_lane;
  reg        ld_to_pc;

  // multi register transfer state
  reg [7:0]  multi_list;
  reg [3:0]  multi_idx;
  reg [31:0] multi_addr;
  reg [3:0]  multi_base;
  reg        multi_load;
  reg        multi_writeback;
  reg        multi_extra;     // lr on push, pc on pop
  reg        multi_doing_extra;

  reg        stepping;
  reg        halt_pending;

  assign dbg_halted = (state == ST_HALTED);
  assign dbg_lockup = lockup;

  // states waiting on bus read data. holding these while the slave is not ready
  // is all that wait state support costs the core
  wire in_data_phase = (state == ST_RST_SP_D) || (state == ST_RST_PC_D) ||
                       (state == ST_FETCH_D)  || (state == ST_FETCH2_D) ||
                       (state == ST_MEM_D)    || (state == ST_MULTI_D) ||
                       (state == ST_EXC_VEC_D) || (state == ST_EXC_POP_D) ||
                       (state == ST_EXC_PUSH_D);

  // a debug event (vector catch, bkpt, completed step) has to latch c_halt in
  // the scs. without that the core halts and then immediately resumes on the
  // next cycle, because ST_HALTED only stays put while c_halt is asserted
  reg halted_d;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      halted_d <= 1'b0;
    end else begin
      halted_d <= (state == ST_HALTED);
    end
  end

  assign dbg_halt_event = (state == ST_HALTED) && !halted_d;

  // r15 reads as the address of the current instruction plus 4
  function automatic [31:0] rd(input [3:0] i);
    begin
      if (i == 4'd15) begin
        rd = pc + 32'd4;
      end else if (i == 4'd13) begin
        rd = sp_read;
      end else begin
        rd = regs[i];
      end
    end
  endfunction

  wire [31:0] pc_align4 = (pc + 32'd4) & 32'hffff_fffc;

  // add with carry, returns {v, c, result}
  function automatic [33:0] addc(input [31:0] a, input [31:0] b, input cin);
    reg [32:0] sum;
    reg        vf;
    begin
      sum = {1'b0, a} + {1'b0, b} + {32'd0, cin};
      vf  = (a[31] == b[31]) && (sum[31] != a[31]);
      addc = {vf, sum[32], sum[31:0]};
    end
  endfunction

  // shifts return {carry_out, result}, carry_in is passed for the n==0 cases




  function automatic [31:0] rev32(input [31:0] a);
    integer i;
    begin
      for (i = 0; i < 32; i = i + 1) begin
        rev32[i] = a[31 - i];
      end
    end
  endfunction

  // one shifter for the whole instruction set
  //
  // a verilog function is inlined at every call site, and do_lsl/lsr/asr/ror
  // were called from 11 places, so the core carried 11 barrel shifters when at
  // most one can be used per instruction. they are the most expensive single
  // structure in the datapath. this is called exactly once, below the execute
  // casez, and each site now just raises sh_req with an op, a value and an
  // amount.
  //
  // the four ops fold into a single 64-bit right funnel. left shifts get there
  // by reversing in and out: a << m is rev(rev(a) >> m), and the carry falls
  // out of the same rule, since lsl's carry a[32-m] is rev(a)[m-1], which is
  // exactly the bit lsr would report. the fill above the operand is what
  // separates the rest: zero for lsr, the sign for asr, the operand itself for
  // ror. only the amt >= 32 cases stay op specific, and ror never has any
  // because it works modulo 32
  function automatic [32:0] do_shift(input [1:0] op, input [31:0] a,
                                     input [7:0] amt, input cin);
    reg [31:0] in;
    reg [31:0] sres;
    reg [63:0] funnel;
    reg [63:0] fsh;
    reg [4:0]  m;
    reg        co;
    begin
      m  = amt[4:0];
      in = (op == SH_LSL) ? rev32(a) : a;
      case (op)
        SH_ASR:  funnel = {{32{a[31]}}, in};
        SH_ROR:  funnel = {in, in};
        default: funnel = {32'd0, in};
      endcase
      // the low half of the 64-bit funnel is the result. taking it explicitly
      // rather than by implicit truncation, which gowin warns about (EX3791)
      fsh  = funnel >> m;
      sres = fsh[31:0];
      co   = (m == 5'd0) ? cin : in[m - 5'd1];
      if (op == SH_ROR) begin
        // ror only ever uses amt[4:0], so a nonzero amt with m == 0 is a whole
        // rotation: the value is unchanged but the carry is its top bit
        do_shift = (amt == 8'd0) ? {cin, a} :
                   (m == 5'd0)   ? {a[31], a} : {co, sres};
      end else if (amt == 8'd0) begin
        do_shift = {cin, a};
      end else if (amt < 8'd32) begin
        do_shift = {co, (op == SH_LSL) ? rev32(sres) : sres};
      end else if (op == SH_ASR) begin
        do_shift = {a[31], {32{a[31]}}};
      end else if (amt == 8'd32) begin
        do_shift = {(op == SH_LSL) ? a[0] : a[31], 32'd0};
      end else begin
        do_shift = {1'b0, 32'd0};
      end
    end
  endfunction

  function automatic cond_true(input [3:0] cc);
    begin
      case (cc)
        4'h0: cond_true = z_flag;
        4'h1: cond_true = !z_flag;
        4'h2: cond_true = c_flag;
        4'h3: cond_true = !c_flag;
        4'h4: cond_true = n_flag;
        4'h5: cond_true = !n_flag;
        4'h6: cond_true = v_flag;
        4'h7: cond_true = !v_flag;
        4'h8: cond_true = c_flag && !z_flag;
        4'h9: cond_true = !c_flag || z_flag;
        4'ha: cond_true = (n_flag == v_flag);
        4'hb: cond_true = (n_flag != v_flag);
        4'hc: cond_true = !z_flag && (n_flag == v_flag);
        4'hd: cond_true = z_flag || (n_flag != v_flag);
        default: cond_true = 1'b1;
      endcase
    end
  endfunction

  // extract the loaded value from the bus lane the slave returned it in
  function automatic [31:0] ld_extract(input [31:0] word, input [2:0] sz,
                                       input [1:0] lane, input sgn);
    reg [7:0]  b;
    reg [15:0] h;
    begin
      b = word[lane * 8 +: 8];
      h = lane[1] ? word[31:16] : word[15:0];
      case (sz)
        SZ_BYTE: ld_extract = sgn ? {{24{b[7]}}, b} : {24'd0, b};
        SZ_HALF: ld_extract = sgn ? {{16{h[15]}}, h} : {16'd0, h};
        default: ld_extract = word;
      endcase
    end
  endfunction

  // place a store value into the correct bus lane
  function automatic [31:0] st_place(input [31:0] val, input [2:0] sz, input [1:0] lane);
    begin
      case (sz)
        SZ_BYTE: st_place = {4{val[7:0]}};
        SZ_HALF: st_place = {2{val[15:0]}};
        default: st_place = val;
      endcase
    end
  endfunction

  function automatic [3:0] lowest_set(input [7:0] v);
    begin
      if      (v[0]) lowest_set = 4'd0;
      else if (v[1]) lowest_set = 4'd1;
      else if (v[2]) lowest_set = 4'd2;
      else if (v[3]) lowest_set = 4'd3;
      else if (v[4]) lowest_set = 4'd4;
      else if (v[5]) lowest_set = 4'd5;
      else if (v[6]) lowest_set = 4'd6;
      else if (v[7]) lowest_set = 4'd7;
      else           lowest_set = 4'd8;
    end
  endfunction

  function automatic [3:0] popcount8(input [7:0] v);
    begin
      popcount8 = {3'd0, v[0]} + {3'd0, v[1]} + {3'd0, v[2]} + {3'd0, v[3]} +
                  {3'd0, v[4]} + {3'd0, v[5]} + {3'd0, v[6]} + {3'd0, v[7]};
    end
  endfunction

  // scratch, declared here because iverilog wants them at module scope
  reg [33:0] alu;
  reg [32:0] sh;

  // shifter request, consumed once below the execute casez. every shifting
  // instruction writes a register, sets n and z from the result and takes c
  // from the shifted out bit, so the writeback is shared along with the shifter
  reg [3:0]  res_sel;

  // operands and flag enables for the table driven datapath
  reg [31:0] opa, opb;
  reg        f_nz, f_c, f_v;

  // the decode table, see m1core_decode.v
  wire [3:0]  d_ra, d_rb, d_rc, d_rd;
  wire [31:0] d_imm;
  wire [2:0]  d_opa, d_opb;
  wire [4:0]  d_op;
  wire [1:0]  d_shop;
  wire        d_sh_reg, d_wb, d_fnz, d_fc, d_fv, d_legacy;

  m1core_decode u_dec (
    .inst(inst), .inst2(inst2),
    .d_ra(d_ra), .d_rb(d_rb), .d_rc(d_rc), .d_rd(d_rd),
    .d_imm(d_imm),
    .d_opa(d_opa), .d_opb(d_opb), .d_op(d_op),
    .d_shop(d_shop), .d_sh_reg(d_sh_reg),
    .d_wb(d_wb), .d_fnz(d_fnz), .d_fc(d_fc), .d_fv(d_fv),
    .d_legacy(d_legacy)
  );

  // store lane request, same pattern: five sites placed the same operand into
  // a byte lane and only the size differed
  reg        st_req;
  reg [2:0]  st_size;

  reg        sh_req;
  reg [1:0]  sh_op;
  reg [31:0] sh_val;
  reg [7:0]  sh_amt;
  reg [3:0]  sh_rd;

  // adder request, same idea. addc was inlined at 11 sites, which is 11 adders
  // for an instruction set that can only add once per instruction. every one of
  // them sets all four flags; the two shapes differ only in whether a register
  // is written, so cmp and cmn just clear add_wr
  reg        add_req;
  reg        add_wr;
  reg [31:0] add_a;
  reg [31:0] add_b;
  reg        add_cin;
  reg [3:0]  add_rd;
  reg [31:0] res, base, addr, val;
  reg [31:0] rdv, rmv, rnv;
  reg [31:0] msr_val;
  reg [3:0]  rd_i, rn_i, rm_i;
  reg [3:0]  cnt;
  reg [31:0] ldv;

  integer k;

  task automatic set_nz(input [31:0] v);
    begin
      n_flag <= v[31];
      z_flag <= (v == 32'd0);
    end
  endtask

  // write whichever stack pointer is currently selected
  task automatic wr_sp(input [31:0] v);
    begin
      if (use_psp) begin
        sp_process <= v;
      end else begin
        sp_main <= v;
      end
    end
  endtask

  // one halfword of instruction buffer.
  //
  // a fetch reads a whole 32 bit word and keeps one halfword of it: with pc[1]
  // clear, bus_rdata[31:16] is the instruction at pc+2 and was being thrown
  // away every time. keeping it skips the entire three cycle fetch for the
  // next instruction, which on straight line code is every other one.
  //
  // held with its address rather than a "next" flag, so a branch that happens
  // to land on the buffered halfword still hits, and anything else misses
  // without needing to be told
  reg [15:0] ihw_data;
  reg [31:0] ihw_addr;
  reg        ihw_valid;

  // write a general register, r15 is a branch
  task automatic wreg(input [3:0] i, input [31:0] v);
    begin
      if (i == 4'd15) begin
        pc <= v & 32'hffff_fffe;
      end else if (i == 4'd13) begin
        wr_sp(v);
      end else begin
        wb_en = 1'b1; wb_idx = i; wb_data = v;
      end
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= ST_RST_SP_A;
      ihw_valid    <= 1'b0;
      pc           <= 32'd0;
      n_flag       <= 1'b0;
      z_flag       <= 1'b0;
      c_flag       <= 1'b0;
      v_flag       <= 1'b0;
      primask      <= 1'b0;
      sp_main      <= 32'd0;
      sp_process   <= 32'd0;
      mode_handler <= 1'b0;
      control_spsel <= 1'b0;
      ipsr         <= 6'd0;
      cur_prio     <= 3'd6;
      prio_sp      <= 3'd0;
      prio_stack[0] <= 3'd6;
      prio_stack[1] <= 3'd6;
      prio_stack[2] <= 3'd6;
      prio_stack[3] <= 3'd6;
      exc_cnt      <= 3'd0;
      exc_frame    <= 32'd0;
      exc_ret_addr <= 32'd0;
      exc_num      <= 6'd0;
      exc_return   <= 32'd0;
      exc_new_prio <= 3'd6;
      inst_pc      <= 32'd0;
      lockup       <= 1'b0;
      exc_taken    <= 1'b0;
      exc_taken_num <= 6'd0;
      bus_req      <= 1'b0;
      bus_addr     <= 32'd0;
      bus_write    <= 1'b0;
      bus_size     <= SZ_WORD;
      bus_wdata    <= 32'd0;
      inst         <= 16'd0;
      inst2        <= 16'd0;
      is32         <= 1'b0;
      stepping     <= 1'b0;
      halt_pending <= 1'b0;
      dbg_bkpt_hit <= 1'b0;
      dreg_ack     <= 1'b0;
      dreg_rdata   <= 32'd0;
      multi_list   <= 8'd0;
      multi_idx    <= 4'd0;
      multi_addr   <= 32'd0;
      multi_base   <= 4'd0;
      multi_load   <= 1'b0;
      multi_writeback <= 1'b0;
      multi_extra  <= 1'b0;
      multi_doing_extra <= 1'b0;
      ld_rd        <= 4'd0;
      ld_signed    <= 1'b0;
      ld_is_load   <= 1'b0;
      ld_size      <= SZ_WORD;
      ld_lane      <= 2'd0;
      ld_to_pc     <= 1'b0;
      for (k = 0; k < 15; k = k + 1) begin
        regs[k] <= 32'd0;
      end
    end else if (sys_reset_req) begin
      mode_handler  <= 1'b0;
      control_spsel <= 1'b0;
      ipsr          <= 6'd0;
      cur_prio      <= 3'd6;
      prio_sp       <= 3'd0;
      lockup        <= 1'b0;
      exc_taken     <= 1'b0;
      // aircr.sysresetreq from the debugger. with no nrst wired this is the
      // only reset path gdb has, and without it a load leaves the core halted
      // at a stale pc with a stale sp, so resuming runs the old image
      state    <= ST_RST_SP_A;
      ihw_valid <= 1'b0;
      bus_req  <= 1'b0;
      dreg_ack <= 1'b0;
      n_flag   <= 1'b0;
      z_flag   <= 1'b0;
      c_flag   <= 1'b0;
      v_flag   <= 1'b0;
      primask  <= 1'b0;
      stepping <= 1'b0;
    end else if (in_data_phase && !bus_ready) begin
      // slave is inserting wait states, hold everything
      dreg_ack <= 1'b0;
    end else begin
      dreg_ack  <= 1'b0;
      exc_taken <= 1'b0;
      wb_en     = 1'b0;

      case (state)
        // reset vector fetch: msp from word 0, pc from word 1
        ST_RST_SP_A: begin
          bus_req   <= 1'b1;
          bus_addr  <= 32'd0;
          bus_write <= 1'b0;
          bus_size  <= SZ_WORD;
          if (bus_gnt) begin
            bus_req <= 1'b0;
            state   <= ST_RST_SP_D;
          end
        end

        ST_RST_SP_D: begin
          sp_main <= bus_rdata;
          state    <= ST_RST_PC_A;
        end

        ST_RST_PC_A: begin
          bus_req   <= 1'b1;
          bus_addr  <= 32'd4;
          bus_write <= 1'b0;
          bus_size  <= SZ_WORD;
          if (bus_gnt) begin
            bus_req <= 1'b0;
            state   <= ST_RST_PC_D;
          end
        end

        ST_RST_PC_D: begin
          pc    <= bus_rdata & 32'hffff_fffe;
          // vc_corereset is demcr's vector catch on reset. bmp sets it on
          // attach so the core stops at the reset handler instead of running
          // away, which is what makes load then run land somewhere useful
          if (dbg_en && (dbg_halt_req || vc_corereset)) begin
            state <= ST_HALTED;
          end else begin
            state <= ST_FETCH_A;
          end
        end

        ST_HALTED: begin
          stepping <= 1'b0;
          // gdb load writes itcm through the debug port while stopped, so a
          // halfword buffered before the halt may be stale by the time the
          // core resumes. cheaper to drop it than to snoop the fabric
          ihw_valid <= 1'b0;
          // serve debugger register accesses while stopped
          if (dreg_req && !dreg_ack) begin
            dreg_ack <= 1'b1;
            if (dreg_wnr) begin
              case (dreg_sel)
                5'd15:   pc <= dreg_wdata & 32'hffff_fffe;
                5'd16:   {n_flag, z_flag, c_flag, v_flag} <= dreg_wdata[31:28];
                5'd20:   primask <= dreg_wdata[0];
                default: if (dreg_sel <= 5'd14) begin
                  wb_en   = 1'b1;
                  wb_idx  = dreg_sel[3:0];
                  wb_data = dreg_wdata;
                end
              endcase
            end else begin
              case (dreg_sel)
                5'd15:   dreg_rdata <= pc;
                5'd16:   dreg_rdata <= {n_flag, z_flag, c_flag, v_flag, 4'd0,
                                        16'd0, 8'd0};
                5'd13:   dreg_rdata <= sp_read;
                5'd17:   dreg_rdata <= sp_main;
                5'd18:   dreg_rdata <= sp_process;
                5'd20:   dreg_rdata <= {31'd0, primask};
                default: dreg_rdata <= (dreg_sel <= 5'd14) ? regs[dreg_sel[3:0]] : 32'd0;
              endcase
            end
          // halted_d gates the resume by one cycle. when the core stops itself
          // the scs needs that cycle to latch c_halt, and without the gate the
          // core sees c_halt still clear and resumes immediately, executing one
          // instruction past the halt point
          end else if (halted_d && dbg_en && !dbg_halt_req) begin
            dbg_bkpt_hit <= 1'b0;
            stepping     <= dbg_step_req;
            state        <= ST_FETCH_A;
          end else if (halted_d && !dbg_en) begin
            dbg_bkpt_hit <= 1'b0;
            state        <= ST_FETCH_A;
          end
        end

        ST_FETCH_A: begin
          // an instruction boundary is the only place an asynchronous exception
          // is allowed in. the not yet executed instruction's address is the
          // return address
          if (exc_ready) begin
            exc_num      <= pend_num;
            exc_ret_addr <= pc;
            exc_new_prio <= pend_prio;
            exc_cnt      <= 3'd0;
            bus_req      <= 1'b0;
            state        <= ST_EXC_PUSH_A;
          end else if (ihw_valid && ihw_addr == pc) begin
            // already have it. no bus cycle, no grant handshake, straight to
            // decode. this is the whole point of the buffer
            inst_pc   <= pc;
            inst      <= ihw_data;
            ihw_valid <= 1'b0;
            if (ihw_data[15:11] >= 5'b11101) begin
              is32  <= 1'b1;
              state <= ST_FETCH2_A;
            end else begin
              is32  <= 1'b0;
              state <= ST_DECODE;
            end
          end else begin
            inst_pc   <= pc;
            bus_req   <= 1'b1;
            bus_addr  <= pc;
            bus_write <= 1'b0;
            bus_size  <= SZ_HALF;
            if (bus_gnt) begin
              bus_req <= 1'b0;
              state   <= ST_FETCH_D;
            end
          end
        end

        ST_FETCH_D: begin
          inst <= pc[1] ? bus_rdata[31:16] : bus_rdata[15:0];
          // with pc[1] clear the upper halfword of the same word is pc+2
          if (!pc[1]) begin
            ihw_data  <= bus_rdata[31:16];
            ihw_addr  <= pc + 32'd2;
            ihw_valid <= 1'b1;
          end
          // 32-bit thumb encodings all start 111xx with xx != 00
          if ((pc[1] ? bus_rdata[31:27] : bus_rdata[15:11]) >= 5'b11101) begin
            is32  <= 1'b1;
            state <= ST_FETCH2_A;
          end else begin
            is32  <= 1'b0;
            state <= ST_DECODE;
          end
        end

        ST_FETCH2_A: begin
          if (ihw_valid && ihw_addr == pc + 32'd2) begin
            // the first fetch of a 32-bit instruction buffered its own second
            // halfword, so this whole access is already paid for
            inst2     <= ihw_data;
            ihw_valid <= 1'b0;
            state     <= ST_DECODE;
          end else begin
            bus_req   <= 1'b1;
            bus_addr  <= pc + 32'd2;
            bus_write <= 1'b0;
            bus_size  <= SZ_HALF;
            if (bus_gnt) begin
              bus_req <= 1'b0;
              state   <= ST_FETCH2_D;
            end
          end
        end

        ST_FETCH2_D: begin
          inst2 <= pc[1] ? bus_rdata[15:0] : bus_rdata[31:16];
          // with pc[1] set, this access was word aligned at pc+2, so the upper
          // halfword is the instruction after the 32-bit one
          if (pc[1]) begin
            ihw_data  <= bus_rdata[31:16];
            ihw_addr  <= pc + 32'd4;
            ihw_valid <= 1'b1;
          end
          state <= ST_DECODE;
        end

        ST_DECODE: begin
          r_a   <= rd(a_idx);
          r_b   <= rd(b_idx);
          r_c   <= rd(c_idx);
          sp_q  <= sp_read;
          state <= ST_EXEC;
        end

        ST_EXEC: begin
          // default: advance past the instruction, overridden by branches
          pc    <= pc + (is32 ? 32'd4 : 32'd2);
          sh_req  = 1'b0;
          add_req = 1'b0;
          st_req  = 1'b0;
          res_sel = RES_NONE;
          f_nz    = 1'b1;
          f_c     = 1'b1;
          f_v     = 1'b1;
          if (stepping || halt_pending) begin
            state <= ST_HALTED;
          end else begin
            state <= ST_FETCH_A;
          end
          if (dbg_en && dbg_halt_req) begin
            state <= ST_HALTED;
          end

          // ---- table driven datapath ----
          //
          // one set of operand muxes, one op select, one writeback, for every
          // instruction the decode table covers. groups it does not cover yet
          // raise d_legacy and fall through to the casez below, so this is
          // brought up a group at a time against the full regression
          if (!d_legacy) begin
            case (d_opa)
              OA_RA:   opa = r_a;
              OA_RB:   opa = r_b;
              OA_RC:   opa = r_c;
              OA_SP:   opa = sp_q;
              OA_PC4:  opa = pc_align4;
              default: opa = 32'd0;
            endcase
            case (d_opb)
              OB_RA:   opb = r_a;
              OB_RB:   opb = r_b;
              OB_RC:   opb = r_c;
              OB_IMM:  opb = d_imm;
              default: opb = 32'd0;
            endcase

            f_nz = d_fnz;
            f_c  = d_fc;
            f_v  = d_fv;

            case (d_op)
              OP_ADD, OP_ADC, OP_SUB, OP_SBC: begin
                add_req = 1'b1;
                add_wr  = d_wb;
                add_rd  = d_rd;
                add_a   = opa;
                add_b   = (d_op == OP_SUB || d_op == OP_SBC) ? ~opb : opb;
                add_cin = (d_op == OP_SUB) ? 1'b1 :
                          (d_op == OP_ADD) ? 1'b0 : c_flag;
              end
              OP_SHIFT: begin
                sh_req = 1'b1;
                sh_op  = d_shop;
                sh_rd  = d_rd;
                sh_val = opa;
                sh_amt = d_sh_reg ? opb[7:0] : d_imm[7:0];
              end
              default: begin
                case (d_op)
                  OP_AND:  res = opa & opb;
                  OP_ORR:  res = opa | opb;
                  OP_EOR:  res = opa ^ opb;
                  OP_BIC:  res = opa & ~opb;
                  OP_MVN:  res = ~opb;
                  OP_MUL:  res = opa * opb;
                  default: res = opb;            // mov
                endcase
                res_sel = RES_RES;
                if (d_wb) begin
                  wb_en  = 1'b1;
                  wb_idx = d_rd;
                end
                if (d_fnz) begin
                  set_nz(res);
                end
              end
            endcase
          end else
          casez (inst[15:10])
            // ---- special data processing and branch exchange ----
            6'b010001: begin
              rd_i = {inst[7], inst[2:0]};
              rm_i = inst[6:3];
              rdv  = r_a;
              rmv  = r_b;
              case (inst[9:8])
                2'b00: begin  // add reg, no flags
                  wreg(rd_i, rdv + rmv);
                end
                2'b01: begin  // cmp reg, flags only
                  add_req = 1'b1; add_wr = 1'b0;
                  add_a = rdv; add_b = ~rmv; add_cin = 1'b1;
                end
                2'b10: begin  // mov reg, no flags
                  wreg(rd_i, rmv);
                end
                default: begin  // bx / blx
                  if (inst[7]) begin
                    wb_en = 1'b1; wb_idx = 4'd14; res_sel = RES_LR2;
                  end
                  // in handler mode a branch to an EXC_RETURN magic value is an
                  // exception return, not a branch. this is how every handler
                  // written in c gets back, via bx lr
                  if (mode_handler && (rmv[31:4] == 28'hfffffff)) begin
                    exc_return <= rmv;
                    exc_frame  <= rmv[2] ? sp_process : sp_main;
                    exc_cnt    <= 3'd0;
                    state      <= ST_EXC_POP_A;
                  end else if (!rmv[0]) begin
                    // armv6-m has no arm state, so a branch target with the
                    // thumb bit clear is a fault. silently masking it, which is
                    // what this used to do, turns a bad function pointer into
                    // wild execution instead of a diagnosable stop
                    exc_num      <= EXC_HARDFAULT;
                    exc_ret_addr <= pc;
                    exc_new_prio <= PRIO_HARDFAULT;
                    exc_cnt      <= 3'd0;
                    state        <= ST_EXC_PUSH_A;
                  end else begin
                    pc <= rmv & 32'hffff_fffe;
                  end
                end
              endcase
            end

            // ---- ldr literal ----
            6'b01001?: begin
              ld_rd      <= {1'b0, inst[10:8]};
              ld_is_load <= 1'b1;
              ld_signed  <= 1'b0;
              ld_size    <= SZ_WORD;
              ld_lane    <= 2'd0;
              ld_to_pc   <= 1'b0;
              bus_addr   <= pc_align4 + {22'd0, inst[7:0], 2'b00};
              bus_write  <= 1'b0;
              bus_size   <= SZ_WORD;
              bus_req    <= 1'b1;
              state      <= ST_MEM_A;
            end

            // ---- load/store register offset ----
            6'b0101??: begin
              addr = r_b + r_c;
              ld_rd      <= {1'b0, inst[2:0]};
              ld_lane    <= addr[1:0];
              ld_to_pc   <= 1'b0;
              bus_addr   <= addr;
              bus_req    <= 1'b1;
              state      <= ST_MEM_A;
              case (inst[11:9])
                3'b000: begin  // str
                  ld_is_load <= 1'b0; ld_size <= SZ_WORD; bus_size <= SZ_WORD;
                  bus_write <= 1'b1;
                  st_req = 1'b1; st_size = SZ_WORD;
                end
                3'b001: begin  // strh
                  ld_is_load <= 1'b0; ld_size <= SZ_HALF; bus_size <= SZ_HALF;
                  bus_write <= 1'b1;
                  st_req = 1'b1; st_size = SZ_HALF;
                end
                3'b010: begin  // strb
                  ld_is_load <= 1'b0; ld_size <= SZ_BYTE; bus_size <= SZ_BYTE;
                  bus_write <= 1'b1;
                  st_req = 1'b1; st_size = SZ_BYTE;
                end
                3'b011: begin  // ldrsb
                  ld_is_load <= 1'b1; ld_size <= SZ_BYTE; ld_signed <= 1'b1;
                  bus_size <= SZ_BYTE; bus_write <= 1'b0;
                end
                3'b100: begin  // ldr
                  ld_is_load <= 1'b1; ld_size <= SZ_WORD; ld_signed <= 1'b0;
                  bus_size <= SZ_WORD; bus_write <= 1'b0;
                end
                3'b101: begin  // ldrh
                  ld_is_load <= 1'b1; ld_size <= SZ_HALF; ld_signed <= 1'b0;
                  bus_size <= SZ_HALF; bus_write <= 1'b0;
                end
                3'b110: begin  // ldrb
                  ld_is_load <= 1'b1; ld_size <= SZ_BYTE; ld_signed <= 1'b0;
                  bus_size <= SZ_BYTE; bus_write <= 1'b0;
                end
                default: begin  // ldrsh
                  ld_is_load <= 1'b1; ld_size <= SZ_HALF; ld_signed <= 1'b1;
                  bus_size <= SZ_HALF; bus_write <= 1'b0;
                end
              endcase
            end

            // ---- load/store word and byte, immediate offset ----
            6'b011???: begin
              if (inst[12]) begin
                addr = r_b + {26'd0, inst[10:6]};
              end else begin
                addr = r_b + {24'd0, inst[10:6], 2'b00};
              end
              ld_rd     <= {1'b0, inst[2:0]};
              ld_lane   <= addr[1:0];
              ld_signed <= 1'b0;
              ld_to_pc  <= 1'b0;
              ld_size   <= inst[12] ? SZ_BYTE : SZ_WORD;
              bus_addr  <= addr;
              bus_size  <= inst[12] ? SZ_BYTE : SZ_WORD;
              bus_req   <= 1'b1;
              state     <= ST_MEM_A;
              if (inst[11]) begin
                ld_is_load <= 1'b1;
                bus_write  <= 1'b0;
              end else begin
                ld_is_load <= 1'b0;
                bus_write  <= 1'b1;
                st_req = 1'b1; st_size = inst[12] ? SZ_BYTE : SZ_WORD;
              end
            end

            // ---- load/store halfword immediate ----
            6'b1000??: begin
              addr = r_b + {25'd0, inst[10:6], 1'b0};
              ld_rd     <= {1'b0, inst[2:0]};
              ld_lane   <= addr[1:0];
              ld_signed <= 1'b0;
              ld_size   <= SZ_HALF;
              ld_to_pc  <= 1'b0;
              bus_addr  <= addr;
              bus_size  <= SZ_HALF;
              bus_req   <= 1'b1;
              state     <= ST_MEM_A;
              if (inst[11]) begin
                ld_is_load <= 1'b1;
                bus_write  <= 1'b0;
              end else begin
                ld_is_load <= 1'b0;
                bus_write  <= 1'b1;
                st_req = 1'b1; st_size = SZ_HALF;
              end
            end

            // ---- load/store sp relative ----
            6'b1001??: begin
              addr = sp_q + {22'd0, inst[7:0], 2'b00};
              ld_rd     <= {1'b0, inst[10:8]};
              ld_lane   <= addr[1:0];
              ld_signed <= 1'b0;
              ld_size   <= SZ_WORD;
              ld_to_pc  <= 1'b0;
              bus_addr  <= addr;
              bus_size  <= SZ_WORD;
              bus_req   <= 1'b1;
              state     <= ST_MEM_A;
              if (inst[11]) begin
                ld_is_load <= 1'b1;
                bus_write  <= 1'b0;
              end else begin
                ld_is_load <= 1'b0;
                bus_write  <= 1'b1;
                bus_wdata  <= r_c;
              end
            end

            // ---- adr and add sp, immediate ----
            6'b1010??: begin
              rd_i = {1'b0, inst[10:8]};
              if (inst[11]) begin
                wb_en = 1'b1; wb_idx = rd_i; res_sel = RES_SPIMM;
              end else begin
                wb_en = 1'b1; wb_idx = rd_i; res_sel = RES_PCIMM;
              end
            end

            // ---- miscellaneous 16-bit ----
            6'b1011??: begin
              casez (inst[11:5])
                // add/sub sp, immediate
                // the immediate is scaled by 4, not 2, so sp stays word aligned
                7'b0000_???: begin
                  if (inst[7]) begin
                    wr_sp(sp_q - {23'd0, inst[6:0], 2'b00});
                  end else begin
                    wr_sp(sp_q + {23'd0, inst[6:0], 2'b00});
                  end
                end
                // sign and zero extend
                7'b0010_???: begin
                  rd_i = {1'b0, inst[2:0]};
                  rm_i = {1'b0, inst[5:3]};
                  rmv  = r_b;
                  wb_en = 1'b1; wb_idx = rd_i; res_sel = RES_EXT;
                end
                // byte reverse
                7'b1010_???: begin
                  rd_i = {1'b0, inst[2:0]};
                  rm_i = {1'b0, inst[5:3]};
                  rmv  = r_b;
                  wb_en = 1'b1; wb_idx = rd_i; res_sel = RES_REV;
                end
                // cps
                7'b0110_011: begin
                  primask <= inst[4];
                end
                // bkpt, halt so the debugger sees it
                7'b1110_???: begin
                  dbg_bkpt_hit <= 1'b1;
                  state        <= ST_HALTED;
                  pc           <= pc;
                end
                // hints, all nops here
                7'b1111_???: begin
                end
                default: begin
                  // push and pop
                  if (inst[11:9] == 3'b010 || inst[11:9] == 3'b110) begin
                    cnt = popcount8(inst[7:0]) + {3'd0, inst[8]};
                    if (cnt == 4'd0) begin
                      // an empty list is unpredictable, treat as a nop
                    end else if (inst[11]) begin
                      // pop, load upward from sp
                      multi_load        <= 1'b1;
                      multi_list        <= inst[7:0];
                      multi_addr        <= sp_q;
                      multi_extra       <= inst[8];
                      multi_doing_extra <= 1'b0;
                      multi_writeback   <= 1'b0;
                      wr_sp(sp_q + {26'd0, cnt, 2'b00});
                      state             <= ST_MULTI_A;
                    end else begin
                      // push, store downward, lowest register at lowest address
                      multi_load        <= 1'b0;
                      multi_list        <= inst[7:0];
                      multi_addr        <= sp_q - {26'd0, cnt, 2'b00};
                      multi_extra       <= inst[8];
                      multi_doing_extra <= 1'b0;
                      multi_writeback   <= 1'b0;
                      wr_sp(sp_q - {26'd0, cnt, 2'b00});
                      state             <= ST_MULTI_A;
                    end
                  end
                end
              endcase
            end

            // ---- stmia and ldmia ----
            6'b1100??: begin
              if (inst[7:0] == 8'd0) begin
                // unpredictable, nop
              end else begin
                multi_load        <= inst[11];
                multi_list        <= inst[7:0];
                multi_addr        <= regs[{1'b0, inst[10:8]}];
                multi_base        <= {1'b0, inst[10:8]};
                multi_extra       <= 1'b0;
                multi_doing_extra <= 1'b0;
                multi_writeback   <= 1'b1;
                state             <= ST_MULTI_A;
              end
            end

            // ---- conditional branch, svc, udf ----
            6'b1101??: begin
              if (inst[11:8] == 4'hf) begin
                // svc is synchronous: taken now, not routed through the nvic.
                // the return address is the instruction after it
                exc_num      <= 6'd11;
                exc_ret_addr <= pc + 32'd2;
                exc_new_prio <= 3'd2;
                exc_cnt      <= 3'd0;
                state        <= ST_EXC_PUSH_A;
              end else if (inst[11:8] == 4'he) begin
                // permanently undefined. a real part takes a hardfault here
                // rather than stopping, so a handler can report it
                exc_num      <= EXC_HARDFAULT;
                exc_ret_addr <= pc;
                exc_new_prio <= PRIO_HARDFAULT;
                exc_cnt      <= 3'd0;
                state        <= ST_EXC_PUSH_A;
              end else if (cond_true(inst[11:8])) begin
                pc <= pc + 32'd4 + {{23{inst[7]}}, inst[7:0], 1'b0};
              end
            end

            // ---- unconditional branch ----
            6'b11100?: begin
              pc <= pc + 32'd4 + {{20{inst[10]}}, inst[10:0], 1'b0};
            end

            // ---- 32-bit encodings ----
            default: begin
              if (inst[15:11] == 5'b11110 && inst2[15:14] == 2'b11) begin
                // bl, the only 32-bit branch in armv6-m
                wb_en = 1'b1; wb_idx = 4'd14; res_sel = RES_LR4;
                pc <= pc + 32'd4 +
                      {{8{inst[10]}},
                       inst[10] ^ ~inst2[13], inst[10] ^ ~inst2[11],
                       inst[9:0], inst2[10:0], 1'b0};
              // mrs: hw1 = 0xf3ef, hw2 = 10x0 Rd[3:0] SYSm[7:0]
              // msr: hw1 = 0xf380|Rn, hw2 = 0x8800 | SYSm[7:0]
              // these are what an rtos uses to reach psp and control, so
              // leaving them as nops silently breaks any context switch
              end else if (inst[15:4] == 12'hf3e && inst2[15:14] == 2'b10) begin
                // mrs Rd, SYSm
                wb_en = 1'b1; wb_idx = inst2[11:8]; res_sel = RES_MRS;
              end else if (inst[15:4] == 12'hf38 && inst2[15:14] == 2'b10) begin
                // msr SYSm, Rn
                // the operand has to land in a temporary first: assigning a
                // masked 32 bit value straight into a one bit reg keeps bit 0,
                // so `msr CONTROL, r0` with r0=2 would silently store zero and
                // spsel would never be set
                msr_val = r_a;
                case (inst2[7:0])
                  // apsr, iapsr, eapsr and xpsr all write the condition flags.
                  // ipsr and epsr are read only, so only the top four bits
                  // land. these were missing entirely: msr apsr fell through to
                  // the default and did nothing, so the flags kept whatever the
                  // previous instruction left. mrs already read them back, which
                  // is what made it look like it worked
                  8'd0, 8'd1, 8'd2, 8'd3: begin
                    n_flag <= msr_val[31];
                    z_flag <= msr_val[30];
                    c_flag <= msr_val[29];
                    v_flag <= msr_val[28];
                  end
                  8'd8:  sp_main    <= msr_val & 32'hffff_fffc;
                  8'd9:  sp_process <= msr_val & 32'hffff_fffc;
                  8'd16: primask    <= msr_val[0];
                  // control is only writable from thread mode
                  8'd20: if (!mode_handler) control_spsel <= msr_val[1];
                  default: begin
                  end
                endcase
              end else begin
                // dsb, dmb, isb and anything else 32-bit: nothing to do on a
                // core with no store buffer or cache
              end
            end
          endcase

          // the one shifter and the one adder, with their writebacks. every
          // shifting or adding instruction above raises a request instead of
          // building its own datapath
          if (sh_req) begin
            sh = do_shift(sh_op, sh_val, sh_amt, c_flag);
            wb_en = 1'b1; wb_idx = sh_rd; res_sel = RES_SHIFT;
            if (f_nz) begin
              set_nz(sh[31:0]);
            end
            if (f_c) begin
              c_flag <= sh[32];
            end
          end
          if (st_req) begin
            bus_wdata <= st_place(r_a, st_size, addr[1:0]);
          end
          if (add_req) begin
            alu = addc(add_a, add_b, add_cin);
            if (add_wr) begin
              wb_en = 1'b1; wb_idx = add_rd; res_sel = RES_ALU;
            end
            if (f_nz) begin
              set_nz(alu[31:0]);
            end
            if (f_c) begin
              c_flag <= alu[32];
            end
            if (f_v) begin
              v_flag <= alu[33];
            end
          end

          // the one result mux.
          //
          // casez has priority semantics, so assigning wb_data at twenty sites
          // inside the execute casez builds a twenty deep chain of 32-bit
          // muxes. the timing report showed exactly that: eleven logic levels
          // between the last decode node and the register file, on every one
          // of the twenty five worst paths.
          //
          // each site sets a 4-bit code instead. a casez over inst[15:10]
          // producing four bits is a handful of lut6s rather than a chain, and
          // the value is selected once here, in a balanced case. this is the
          // same shape that took the nvic from 25.7 to 33.4 MHz.
          //
          // RES_NONE deliberately assigns nothing: wreg() and the states other
          // than execute write wb_data directly, and must not be overwritten
          case (res_sel)
            RES_ALU:   wb_data = alu[31:0];
            RES_SHIFT: wb_data = sh[31:0];
            RES_RES:   wb_data = res;
            RES_SPIMM: wb_data = sp_q + {22'd0, inst[7:0], 2'b00};
            RES_PCIMM: wb_data = pc_align4 + {22'd0, inst[7:0], 2'b00};
            RES_LR2:   wb_data = (pc + 32'd2) | 32'd1;
            RES_LR4:   wb_data = (pc + 32'd4) | 32'd1;
            RES_EXT: begin
              case (inst[7:6])
                2'b00:   wb_data = {{16{rmv[15]}}, rmv[15:0]};
                2'b01:   wb_data = {{24{rmv[7]}}, rmv[7:0]};
                2'b10:   wb_data = {16'd0, rmv[15:0]};
                default: wb_data = {24'd0, rmv[7:0]};
              endcase
            end
            RES_REV: begin
              case (inst[7:6])
                2'b00:   wb_data = {rmv[7:0], rmv[15:8],
                                    rmv[23:16], rmv[31:24]};
                2'b01:   wb_data = {rmv[23:16], rmv[31:24],
                                    rmv[7:0], rmv[15:8]};
                default: wb_data = {{16{rmv[7]}}, rmv[7:0],
                                    rmv[15:8]};
              endcase
            end
            RES_MRS: begin
              case (inst2[7:0])
                8'd0,
                8'd3:    wb_data = {n_flag, z_flag, c_flag, v_flag,
                                    22'd0, ipsr};
                8'd5:    wb_data = {26'd0, ipsr};
                8'd8:    wb_data = sp_main;
                8'd9:    wb_data = sp_process;
                8'd16:   wb_data = {31'd0, primask};
                8'd20:   wb_data = {30'd0, control_spsel, 1'b0};
                default: wb_data = 32'd0;
              endcase
            end
            default: begin
            end
          endcase
        end

        // single memory access
        ST_MEM_A: begin
          // armv6-m has no unaligned access support at all: a word access must
          // be word aligned and a halfword access halfword aligned. the srams
          // mask the address rather than complaining, so without this check a
          // misaligned pointer silently reads the wrong location
          if ((bus_size == SZ_WORD && bus_addr[1:0] != 2'b00) ||
              (bus_size == SZ_HALF && bus_addr[0] != 1'b0)) begin
            bus_req      <= 1'b0;
            exc_num      <= EXC_HARDFAULT;
            exc_ret_addr <= inst_pc;
            exc_new_prio <= PRIO_HARDFAULT;
            exc_cnt      <= 3'd0;
            state        <= ST_EXC_PUSH_A;
          end else begin
            bus_req <= 1'b1;
            if (bus_gnt) begin
              bus_req <= 1'b0;
              state   <= ST_MEM_D;
            end
          end
        end

        ST_MEM_D: begin
          if (bus_write) begin
            ihw_valid <= 1'b0;
          end
          if (ld_is_load) begin
            ldv = ld_extract(bus_rdata, ld_size, ld_lane, ld_signed);
            if (ld_to_pc) begin
              pc <= ldv & 32'hffff_fffe;
            end else begin
              wb_en = 1'b1; wb_idx = ld_rd; wb_data = ldv;
            end
          end
          if (stepping || (dbg_en && dbg_halt_req)) begin
            state <= ST_HALTED;
          end else begin
            state <= ST_FETCH_A;
          end
        end

        // multi register transfer, one register per pass
        ST_MULTI_A: begin
          if (multi_list == 8'd0 && !multi_extra) begin
            if (multi_writeback) begin
              wb_en = 1'b1; wb_idx = multi_base; wb_data = multi_addr;
            end
            if (stepping || (dbg_en && dbg_halt_req)) begin
              state <= ST_HALTED;
            end else begin
              state <= ST_FETCH_A;
            end
          end else begin
            bus_req   <= 1'b1;
            bus_addr  <= multi_addr;
            bus_size  <= SZ_WORD;
            bus_write <= !multi_load;
            if (multi_list == 8'd0) begin
              // the lr/pc slot, which sits above all the numbered registers
              multi_doing_extra <= 1'b1;
              bus_wdata <= regs[14];
            end else begin
              multi_doing_extra <= 1'b0;
              bus_wdata <= regs[lowest_set(multi_list)];
            end
            if (bus_gnt) begin
              bus_req <= 1'b0;
              state   <= ST_MULTI_D;
            end
          end
        end

        ST_MULTI_D: begin
          // an EXC_RETURN value popped into pc means this is a handler
          // returning with pop {pc}, not an ordinary branch. it has to be
          // decided here and it has to win: the state assignment at the end of
          // this block would otherwise overwrite the jump to the unstack and
          // silently drop the return, leaving execution to run off the end of
          // the handler
          if (multi_load && multi_doing_extra && mode_handler &&
              (bus_rdata[31:4] == 28'hfffffff)) begin
            exc_return  <= bus_rdata;
            exc_frame   <= bus_rdata[2] ? sp_process : sp_main;
            exc_cnt     <= 3'd0;
            multi_extra <= 1'b0;
            state       <= ST_EXC_POP_A;
          end else begin
            if (multi_load) begin
              if (multi_doing_extra) begin
                pc <= bus_rdata & 32'hffff_fffe;
              end else begin
                wb_en   = 1'b1;
                wb_idx  = lowest_set(multi_list);
                wb_data = bus_rdata;
              end
            end
            if (multi_doing_extra) begin
              multi_extra <= 1'b0;
            end else begin
              multi_list <= multi_list & ~(8'd1 << lowest_set(multi_list));
            end
            multi_addr <= multi_addr + 32'd4;
            state      <= ST_MULTI_A;
          end
        end

        // -------------------------------------------------------------------
        // exception entry: stack 8 words, then vector fetch
        //
        // frame layout, low address first: r0 r1 r2 r3 r12 lr returnaddr xpsr
        // -------------------------------------------------------------------
        ST_EXC_PUSH_A: begin
          // a fault while already running at hardfault priority has nowhere to
          // escalate to. real hardware locks up; stopping here is the same
          // thing and leaves the debugger something to look at
          if (exc_num == EXC_HARDFAULT && cur_prio <= PRIO_HARDFAULT) begin
            lockup  <= 1'b1;
            bus_req <= 1'b0;
            state   <= ST_HALTED;
          end else begin
          bus_req   <= 1'b1;
          bus_write <= 1'b1;
          bus_size  <= SZ_WORD;
          bus_addr  <= (sp_read - 32'd32) + {27'd0, exc_cnt, 2'b00};
          case (exc_cnt)
            3'd0: bus_wdata <= regs[0];
            3'd1: bus_wdata <= regs[1];
            3'd2: bus_wdata <= regs[2];
            3'd3: bus_wdata <= regs[3];
            3'd4: bus_wdata <= regs[12];
            3'd5: bus_wdata <= regs[14];
            3'd6: bus_wdata <= exc_ret_addr;
            // xpsr. bit 24 is the thumb bit and is always set on armv6-m
            default: bus_wdata <= {n_flag, z_flag, c_flag, v_flag, 3'd0, 1'b1,
                                   18'd0, ipsr};
          endcase
          if (bus_gnt) begin
            bus_req <= 1'b0;
            state   <= ST_EXC_PUSH_D;
          end
          end
        end

        ST_EXC_PUSH_D: begin
          if (exc_cnt == 3'd7) begin
            // the frame is written, now switch into handler mode
            wr_sp(sp_read - 32'd32);
            wb_en = 1'b1; wb_idx = 4'd14; wb_data = mode_handler ? 32'hffff_fff1 :
                        (control_spsel ? 32'hffff_fffd : 32'hffff_fff9);
            prio_stack[prio_sp[1:0]] <= cur_prio;
            prio_sp  <= prio_sp + 3'd1;
            cur_prio <= exc_new_prio;
            mode_handler <= 1'b1;
            ipsr     <= exc_num;
            exc_taken     <= 1'b1;
            exc_taken_num <= exc_num;
            exc_cnt  <= 3'd0;
            state    <= ST_EXC_VEC_A;
          end else begin
            exc_cnt <= exc_cnt + 3'd1;
            state   <= ST_EXC_PUSH_A;
          end
        end

        ST_EXC_VEC_A: begin
          bus_req   <= 1'b1;
          bus_write <= 1'b0;
          bus_size  <= SZ_WORD;
          // no vtor on armv6-m, the table is fixed at zero
          bus_addr  <= {24'd0, exc_num, 2'b00};
          if (bus_gnt) begin
            bus_req <= 1'b0;
            state   <= ST_EXC_VEC_D;
          end
        end

        ST_EXC_VEC_D: begin
          pc    <= bus_rdata & 32'hffff_fffe;
          state <= ST_FETCH_A;
        end

        // -------------------------------------------------------------------
        // exception return: unstack the same 8 words
        // -------------------------------------------------------------------
        ST_EXC_POP_A: begin
          bus_req   <= 1'b1;
          bus_write <= 1'b0;
          bus_size  <= SZ_WORD;
          bus_addr  <= exc_frame + {27'd0, exc_cnt, 2'b00};
          if (bus_gnt) begin
            bus_req <= 1'b0;
            state   <= ST_EXC_POP_D;
          end
        end

        ST_EXC_POP_D: begin
          // the stack frame is r0-r3, r12, lr, pc, xpsr in that order
          if (exc_cnt <= 3'd5) begin
            wb_en   = 1'b1;
            wb_data = bus_rdata;
            case (exc_cnt)
              3'd4:    wb_idx = 4'd12;
              3'd5:    wb_idx = 4'd14;
              default: wb_idx = {1'b0, exc_cnt};
            endcase
          end else if (exc_cnt == 3'd6) begin
            pc <= bus_rdata & 32'hffff_fffe;
          end else begin
            {n_flag, z_flag, c_flag, v_flag} <= bus_rdata[31:28];
            ipsr <= bus_rdata[5:0];
          end

          if (exc_cnt == 3'd7) begin
            // restore the mode and stack selection the exc_return value asks
            // for, then hand the stack space back
            mode_handler  <= !exc_return[3];
            control_spsel <= exc_return[3] ? exc_return[2] : 1'b0;
            if (exc_return[2]) begin
              sp_process <= exc_frame + 32'd32;
            end else begin
              sp_main <= exc_frame + 32'd32;
            end
            if (prio_sp != 3'd0) begin
              cur_prio <= prio_stack[prio_sp[1:0] - 3'd1];
              prio_sp  <= prio_sp - 3'd1;
            end else begin
              cur_prio <= 3'd6;
            end
            exc_cnt <= 3'd0;
            state   <= ST_FETCH_A;
          end else begin
            exc_cnt <= exc_cnt + 3'd1;
            state   <= ST_EXC_POP_A;
          end
        end

        default: begin
          state <= ST_FETCH_A;
        end
      endcase

      // the one register file write port
      //
      // every state above asks for a write by raising wb_en rather than
      // indexing regs itself. that matters more than it looks: verilog infers
      // one write port per distinct index expression, and there were seven of
      // them (rd_i, ld_rd, multi_base, the shifter and adder destinations and
      // two constants), so the file carried seven address decoders and seven
      // enable trees over fifteen 32-bit registers. no two of them can ever
      // fire in the same cycle, because each belongs to a different state or a
      // different branch of execute
      if (wb_en) begin
        regs[wb_idx] <= wb_data;
      end
    end
  end

endmodule

`default_nettype wire

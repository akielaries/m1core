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

  reg [4:0] state;

  // r0-r12 plus r13 sp and r14 lr. pc is separate because it is written by
  // control flow rather than by the register write port
  reg [31:0] regs [0:14];
  reg [31:0] pc;
  reg        n_flag, z_flag, c_flag, v_flag;
  reg        primask;

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

  wire use_psp = !mode_handler && control_spsel;
  wire [31:0] sp_read = use_psp ? sp_process : sp_main;

  // an exception is taken at an instruction boundary when something is pending
  // at a strictly higher priority than what is currently executing. primask
  // masks everything with a configurable priority, which is everything the nvic
  // can present today
  wire exc_ready = pend_valid && (pend_prio < cur_prio) && !primask;

  reg [15:0] inst;
  reg [15:0] inst2;
  reg        is32;

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
  function automatic [32:0] do_lsl(input [31:0] a, input [7:0] amt, input cin);
    begin
      if (amt == 8'd0) begin
        do_lsl = {cin, a};
      end else if (amt < 8'd32) begin
        do_lsl = {a[32 - amt[5:0]], a << amt[4:0]};
      end else if (amt == 8'd32) begin
        do_lsl = {a[0], 32'd0};
      end else begin
        do_lsl = {1'b0, 32'd0};
      end
    end
  endfunction

  function automatic [32:0] do_lsr(input [31:0] a, input [7:0] amt, input cin);
    begin
      if (amt == 8'd0) begin
        do_lsr = {cin, a};
      end else if (amt < 8'd32) begin
        do_lsr = {a[amt[4:0] - 5'd1], a >> amt[4:0]};
      end else if (amt == 8'd32) begin
        do_lsr = {a[31], 32'd0};
      end else begin
        do_lsr = {1'b0, 32'd0};
      end
    end
  endfunction

  function automatic [32:0] do_asr(input [31:0] a, input [7:0] amt, input cin);
    begin
      if (amt == 8'd0) begin
        do_asr = {cin, a};
      end else if (amt < 8'd32) begin
        do_asr = {a[amt[4:0] - 5'd1], $signed(a) >>> amt[4:0]};
      end else begin
        do_asr = {a[31], {32{a[31]}}};
      end
    end
  endfunction

  function automatic [32:0] do_ror(input [31:0] a, input [7:0] amt, input cin);
    reg [4:0] m;
    begin
      m = amt[4:0];
      if (amt == 8'd0) begin
        do_ror = {cin, a};
      end else if (m == 5'd0) begin
        do_ror = {a[31], a};
      end else begin
        do_ror = {a[m - 5'd1], (a >> m) | (a << (6'd32 - {1'b0, m}))};
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
  reg [31:0] res, base, addr, val;
  reg [31:0] rdv, rmv, rnv;
  reg [31:0] msr_val;
  reg [3:0]  rd_i, rn_i, rm_i;
  reg [31:0] imm;
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

  // write a general register, r15 is a branch
  task automatic wreg(input [3:0] i, input [31:0] v);
    begin
      if (i == 4'd15) begin
        pc <= v & 32'hffff_fffe;
      end else if (i == 4'd13) begin
        wr_sp(v);
      end else begin
        regs[i] <= v;
      end
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= ST_RST_SP_A;
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
      exc_taken     <= 1'b0;
      // aircr.sysresetreq from the debugger. with no nrst wired this is the
      // only reset path gdb has, and without it a load leaves the core halted
      // at a stale pc with a stale sp, so resuming runs the old image
      state    <= ST_RST_SP_A;
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
          // serve debugger register accesses while stopped
          if (dreg_req && !dreg_ack) begin
            dreg_ack <= 1'b1;
            if (dreg_wnr) begin
              case (dreg_sel)
                5'd15:   pc <= dreg_wdata & 32'hffff_fffe;
                5'd16:   {n_flag, z_flag, c_flag, v_flag} <= dreg_wdata[31:28];
                5'd20:   primask <= dreg_wdata[0];
                default: if (dreg_sel <= 5'd14) regs[dreg_sel[3:0]] <= dreg_wdata;
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
          end else begin
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
          // 32-bit thumb encodings all start 111xx with xx != 00
          if ((pc[1] ? bus_rdata[31:27] : bus_rdata[15:11]) >= 5'b11101) begin
            is32  <= 1'b1;
            state <= ST_FETCH2_A;
          end else begin
            is32  <= 1'b0;
            state <= ST_EXEC;
          end
        end

        ST_FETCH2_A: begin
          bus_req   <= 1'b1;
          bus_addr  <= pc + 32'd2;
          bus_write <= 1'b0;
          bus_size  <= SZ_HALF;
          if (bus_gnt) begin
            bus_req <= 1'b0;
            state   <= ST_FETCH2_D;
          end
        end

        ST_FETCH2_D: begin
          inst2 <= pc[1] ? bus_rdata[15:0] : bus_rdata[31:16];
          state <= ST_EXEC;
        end

        ST_EXEC: begin
          // default: advance past the instruction, overridden by branches
          pc    <= pc + (is32 ? 32'd4 : 32'd2);
          if (stepping || halt_pending) begin
            state <= ST_HALTED;
          end else begin
            state <= ST_FETCH_A;
          end
          if (dbg_en && dbg_halt_req) begin
            state <= ST_HALTED;
          end

          casez (inst[15:10])
            // ---- shift by immediate, add/sub register or 3-bit immediate ----
            6'b000???: begin
              if (inst[15:11] == 5'b00011) begin
                rd_i = {1'b0, inst[2:0]};
                rn_i = {1'b0, inst[5:3]};
                rm_i = {1'b0, inst[8:6]};
                rnv  = rd(rn_i);
                rmv  = rd(rm_i);
                if (inst[9]) begin
                  alu = addc(rnv, inst[10] ? ~{29'd0, inst[8:6]} : ~rmv, 1'b1);
                end else begin
                  alu = addc(rnv, inst[10] ? {29'd0, inst[8:6]} : rmv, 1'b0);
                end
                regs[rd_i] <= alu[31:0];
                set_nz(alu[31:0]);
                c_flag <= alu[32];
                v_flag <= alu[33];
              end else begin
                rd_i = {1'b0, inst[2:0]};
                rm_i = {1'b0, inst[5:3]};
                rmv  = rd(rm_i);
                case (inst[12:11])
                  2'b00: sh = do_lsl(rmv, {3'd0, inst[10:6]}, c_flag);
                  2'b01: sh = do_lsr(rmv, (inst[10:6] == 5'd0) ? 8'd32 :
                                     {3'd0, inst[10:6]}, c_flag);
                  default: sh = do_asr(rmv, (inst[10:6] == 5'd0) ? 8'd32 :
                                       {3'd0, inst[10:6]}, c_flag);
                endcase
                regs[rd_i] <= sh[31:0];
                set_nz(sh[31:0]);
                c_flag <= sh[32];
              end
            end

            // ---- mov/cmp/add/sub 8-bit immediate ----
            6'b001???: begin
              rd_i = {1'b0, inst[10:8]};
              rdv  = rd(rd_i);
              imm  = {24'd0, inst[7:0]};
              case (inst[12:11])
                2'b00: begin
                  regs[rd_i] <= imm;
                  set_nz(imm);
                end
                2'b01: begin
                  alu = addc(rdv, ~imm, 1'b1);
                  set_nz(alu[31:0]);
                  c_flag <= alu[32];
                  v_flag <= alu[33];
                end
                2'b10: begin
                  alu = addc(rdv, imm, 1'b0);
                  regs[rd_i] <= alu[31:0];
                  set_nz(alu[31:0]);
                  c_flag <= alu[32];
                  v_flag <= alu[33];
                end
                default: begin
                  alu = addc(rdv, ~imm, 1'b1);
                  regs[rd_i] <= alu[31:0];
                  set_nz(alu[31:0]);
                  c_flag <= alu[32];
                  v_flag <= alu[33];
                end
              endcase
            end

            // ---- data processing register ----
            6'b010000: begin
              rd_i = {1'b0, inst[2:0]};
              rm_i = {1'b0, inst[5:3]};
              rdv  = rd(rd_i);
              rmv  = rd(rm_i);
              case (inst[9:6])
                4'h0: begin  // and
                  res = rdv & rmv;
                  regs[rd_i] <= res; set_nz(res);
                end
                4'h1: begin  // eor
                  res = rdv ^ rmv;
                  regs[rd_i] <= res; set_nz(res);
                end
                4'h2: begin  // lsl reg
                  sh = do_lsl(rdv, rmv[7:0], c_flag);
                  regs[rd_i] <= sh[31:0]; set_nz(sh[31:0]); c_flag <= sh[32];
                end
                4'h3: begin  // lsr reg
                  sh = do_lsr(rdv, rmv[7:0], c_flag);
                  regs[rd_i] <= sh[31:0]; set_nz(sh[31:0]); c_flag <= sh[32];
                end
                4'h4: begin  // asr reg
                  sh = do_asr(rdv, rmv[7:0], c_flag);
                  regs[rd_i] <= sh[31:0]; set_nz(sh[31:0]); c_flag <= sh[32];
                end
                4'h5: begin  // adc
                  alu = addc(rdv, rmv, c_flag);
                  regs[rd_i] <= alu[31:0]; set_nz(alu[31:0]);
                  c_flag <= alu[32]; v_flag <= alu[33];
                end
                4'h6: begin  // sbc
                  alu = addc(rdv, ~rmv, c_flag);
                  regs[rd_i] <= alu[31:0]; set_nz(alu[31:0]);
                  c_flag <= alu[32]; v_flag <= alu[33];
                end
                4'h7: begin  // ror
                  sh = do_ror(rdv, rmv[7:0], c_flag);
                  regs[rd_i] <= sh[31:0]; set_nz(sh[31:0]); c_flag <= sh[32];
                end
                4'h8: begin  // tst
                  res = rdv & rmv;
                  set_nz(res);
                end
                4'h9: begin  // rsb rd, rm, #0
                  alu = addc(~rmv, 32'd0, 1'b1);
                  regs[rd_i] <= alu[31:0]; set_nz(alu[31:0]);
                  c_flag <= alu[32]; v_flag <= alu[33];
                end
                4'ha: begin  // cmp
                  alu = addc(rdv, ~rmv, 1'b1);
                  set_nz(alu[31:0]); c_flag <= alu[32]; v_flag <= alu[33];
                end
                4'hb: begin  // cmn
                  alu = addc(rdv, rmv, 1'b0);
                  set_nz(alu[31:0]); c_flag <= alu[32]; v_flag <= alu[33];
                end
                4'hc: begin  // orr
                  res = rdv | rmv;
                  regs[rd_i] <= res; set_nz(res);
                end
                4'hd: begin  // mul
                  res = rmv * rdv;
                  regs[rd_i] <= res; set_nz(res);
                end
                4'he: begin  // bic
                  res = rdv & ~rmv;
                  regs[rd_i] <= res; set_nz(res);
                end
                default: begin  // mvn
                  res = ~rmv;
                  regs[rd_i] <= res; set_nz(res);
                end
              endcase
            end

            // ---- special data processing and branch exchange ----
            6'b010001: begin
              rd_i = {inst[7], inst[2:0]};
              rm_i = inst[6:3];
              rdv  = rd(rd_i);
              rmv  = rd(rm_i);
              case (inst[9:8])
                2'b00: begin  // add reg, no flags
                  wreg(rd_i, rdv + rmv);
                end
                2'b01: begin  // cmp reg, flags only
                  alu = addc(rdv, ~rmv, 1'b1);
                  set_nz(alu[31:0]); c_flag <= alu[32]; v_flag <= alu[33];
                end
                2'b10: begin  // mov reg, no flags
                  wreg(rd_i, rmv);
                end
                default: begin  // bx / blx
                  if (inst[7]) begin
                    regs[14] <= (pc + 32'd2) | 32'd1;
                  end
                  // in handler mode a branch to an EXC_RETURN magic value is an
                  // exception return, not a branch. this is how every handler
                  // written in c gets back, via bx lr
                  if (mode_handler && (rmv[31:4] == 28'hfffffff)) begin
                    exc_return <= rmv;
                    exc_frame  <= rmv[2] ? sp_process : sp_main;
                    exc_cnt    <= 3'd0;
                    state      <= ST_EXC_POP_A;
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
              addr = rd({1'b0, inst[5:3]}) + rd({1'b0, inst[8:6]});
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
                  bus_wdata <= st_place(rd({1'b0, inst[2:0]}), SZ_WORD, addr[1:0]);
                end
                3'b001: begin  // strh
                  ld_is_load <= 1'b0; ld_size <= SZ_HALF; bus_size <= SZ_HALF;
                  bus_write <= 1'b1;
                  bus_wdata <= st_place(rd({1'b0, inst[2:0]}), SZ_HALF, addr[1:0]);
                end
                3'b010: begin  // strb
                  ld_is_load <= 1'b0; ld_size <= SZ_BYTE; bus_size <= SZ_BYTE;
                  bus_write <= 1'b1;
                  bus_wdata <= st_place(rd({1'b0, inst[2:0]}), SZ_BYTE, addr[1:0]);
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
                addr = rd({1'b0, inst[5:3]}) + {26'd0, inst[10:6]};
              end else begin
                addr = rd({1'b0, inst[5:3]}) + {24'd0, inst[10:6], 2'b00};
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
                bus_wdata  <= st_place(rd({1'b0, inst[2:0]}),
                                       inst[12] ? SZ_BYTE : SZ_WORD, addr[1:0]);
              end
            end

            // ---- load/store halfword immediate ----
            6'b1000??: begin
              addr = rd({1'b0, inst[5:3]}) + {25'd0, inst[10:6], 1'b0};
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
                bus_wdata  <= st_place(rd({1'b0, inst[2:0]}), SZ_HALF, addr[1:0]);
              end
            end

            // ---- load/store sp relative ----
            6'b1001??: begin
              addr = sp_read + {22'd0, inst[7:0], 2'b00};
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
                bus_wdata  <= rd({1'b0, inst[10:8]});
              end
            end

            // ---- adr and add sp, immediate ----
            6'b1010??: begin
              rd_i = {1'b0, inst[10:8]};
              if (inst[11]) begin
                regs[rd_i] <= sp_read + {22'd0, inst[7:0], 2'b00};
              end else begin
                regs[rd_i] <= pc_align4 + {22'd0, inst[7:0], 2'b00};
              end
            end

            // ---- miscellaneous 16-bit ----
            6'b1011??: begin
              casez (inst[11:5])
                // add/sub sp, immediate
                // the immediate is scaled by 4, not 2, so sp stays word aligned
                7'b0000_???: begin
                  if (inst[7]) begin
                    wr_sp(sp_read - {23'd0, inst[6:0], 2'b00});
                  end else begin
                    wr_sp(sp_read + {23'd0, inst[6:0], 2'b00});
                  end
                end
                // sign and zero extend
                7'b0010_???: begin
                  rd_i = {1'b0, inst[2:0]};
                  rm_i = {1'b0, inst[5:3]};
                  rmv  = rd(rm_i);
                  case (inst[7:6])
                    2'b00: regs[rd_i] <= {{16{rmv[15]}}, rmv[15:0]};
                    2'b01: regs[rd_i] <= {{24{rmv[7]}}, rmv[7:0]};
                    2'b10: regs[rd_i] <= {16'd0, rmv[15:0]};
                    default: regs[rd_i] <= {24'd0, rmv[7:0]};
                  endcase
                end
                // byte reverse
                7'b1010_???: begin
                  rd_i = {1'b0, inst[2:0]};
                  rm_i = {1'b0, inst[5:3]};
                  rmv  = rd(rm_i);
                  case (inst[7:6])
                    2'b00: regs[rd_i] <= {rmv[7:0], rmv[15:8],
                                          rmv[23:16], rmv[31:24]};
                    2'b01: regs[rd_i] <= {rmv[23:16], rmv[31:24],
                                          rmv[7:0], rmv[15:8]};
                    default: regs[rd_i] <= {{16{rmv[7]}}, rmv[7:0],
                                            rmv[15:8]};
                  endcase
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
                      multi_addr        <= sp_read;
                      multi_extra       <= inst[8];
                      multi_doing_extra <= 1'b0;
                      multi_writeback   <= 1'b0;
                      wr_sp(sp_read + {26'd0, cnt, 2'b00});
                      state             <= ST_MULTI_A;
                    end else begin
                      // push, store downward, lowest register at lowest address
                      multi_load        <= 1'b0;
                      multi_list        <= inst[7:0];
                      multi_addr        <= sp_read - {26'd0, cnt, 2'b00};
                      multi_extra       <= inst[8];
                      multi_doing_extra <= 1'b0;
                      multi_writeback   <= 1'b0;
                      wr_sp(sp_read - {26'd0, cnt, 2'b00});
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
                // permanently undefined
                state <= ST_HALTED;
                pc    <= pc;
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
                regs[14] <= (pc + 32'd4) | 32'd1;
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
                case (inst2[7:0])
                  8'd0,
                  8'd3:    regs[inst2[11:8]] <= {n_flag, z_flag, c_flag, v_flag,
                                                 22'd0, ipsr};
                  8'd5:    regs[inst2[11:8]] <= {26'd0, ipsr};
                  8'd8:    regs[inst2[11:8]] <= sp_main;
                  8'd9:    regs[inst2[11:8]] <= sp_process;
                  8'd16:   regs[inst2[11:8]] <= {31'd0, primask};
                  8'd20:   regs[inst2[11:8]] <= {30'd0, control_spsel, 1'b0};
                  default: regs[inst2[11:8]] <= 32'd0;
                endcase
              end else if (inst[15:4] == 12'hf38 && inst2[15:14] == 2'b10) begin
                // msr SYSm, Rn
                // the operand has to land in a temporary first: assigning a
                // masked 32 bit value straight into a one bit reg keeps bit 0,
                // so `msr CONTROL, r0` with r0=2 would silently store zero and
                // spsel would never be set
                msr_val = rd(inst[3:0]);
                case (inst2[7:0])
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
        end

        // single memory access
        ST_MEM_A: begin
          bus_req <= 1'b1;
          if (bus_gnt) begin
            bus_req <= 1'b0;
            state   <= ST_MEM_D;
          end
        end

        ST_MEM_D: begin
          if (ld_is_load) begin
            ldv = ld_extract(bus_rdata, ld_size, ld_lane, ld_signed);
            if (ld_to_pc) begin
              pc <= ldv & 32'hffff_fffe;
            end else begin
              regs[ld_rd] <= ldv;
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
              regs[multi_base] <= multi_addr;
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
                regs[lowest_set(multi_list)] <= bus_rdata;
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

        ST_EXC_PUSH_D: begin
          if (exc_cnt == 3'd7) begin
            // the frame is written, now switch into handler mode
            wr_sp(sp_read - 32'd32);
            regs[14] <= mode_handler ? 32'hffff_fff1 :
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
          case (exc_cnt)
            3'd0: regs[0]  <= bus_rdata;
            3'd1: regs[1]  <= bus_rdata;
            3'd2: regs[2]  <= bus_rdata;
            3'd3: regs[3]  <= bus_rdata;
            3'd4: regs[12] <= bus_rdata;
            3'd5: regs[14] <= bus_rdata;
            3'd6: pc       <= bus_rdata & 32'hffff_fffe;
            default: begin
              {n_flag, z_flag, c_flag, v_flag} <= bus_rdata[31:28];
              ipsr <= bus_rdata[5:0];
            end
          endcase

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
    end
  end

endmodule

`default_nettype wire

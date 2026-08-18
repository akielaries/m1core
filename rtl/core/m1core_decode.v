`default_nettype none

// m1core instruction decode
//
// combinational: a thumb halfword in, a control word out. this exists to get
// the per instruction control out of the execute casez.
//
// the multi-cycle core derived control inside each of 31 casez branches, and
// because casez has priority semantics that builds priority chains rather than
// muxes, and because each branch wrote the register file with its own index
// expression it built one write port decoder per branch. the core measured 3x
// the size of an equivalent cortex-m1 and its critical path was 11 levels of
// writeback mux. a table does not have that shape: every instruction drives
// the same datapath, and the only thing that varies is the control word.
//
// it is also the pipeline register. a 3-stage machine registers exactly this
// between decode and execute, so building it inside the multi-cycle core first
// is not a detour -- it is the same structure, verified where the exception,
// debug and nvic logic already work.
//
// LEGACY is the escape hatch. groups still handled by the old casez set it and
// execute falls through to the existing path, so this can be brought up one
// group at a time against the full regression rather than in one jump.

module m1core_decode (
  input  wire [15:0] inst,
  input  wire [15:0] inst2,     // second halfword, valid when d_is32

  // register indices. the file has three read ports, see the cpu
  // the three read port indices are continuous, computed straight from
  // instruction bits rather than falling out of the casez below. the register
  // file read cannot start until these are known, and taking them from the
  // full decoder put the whole decode in front of it: the timing report showed
  // q_head -> queue -> decode -> d_ra -> register file -> operand mux as one
  // combinational path. these are three small muxes instead
  output wire [3:0]  d_ra,        // port a, {x, inst[2:0]}
  output wire [3:0]  d_rb,        // port b, {x, inst[5:3]}
  output wire [3:0]  d_rc,        // port c, inst[8:6] or inst[10:8]
  output reg  [3:0]  d_rd,        // destination

  output reg  [31:0] d_imm,

  output reg  [2:0]  d_opa,       // operand a source
  output reg  [2:0]  d_opb,       // operand b source
  output reg  [4:0]  d_op,        // what the datapath does
  output reg  [1:0]  d_shop,      // shift kind when d_op is OP_SHIFT
  output reg         d_sh_reg,    // shift amount from a register, not imm5

  output reg         d_wb,        // writes d_rd
  output reg         d_fnz,       // writes n and z
  output reg         d_fc,        // writes c
  output reg         d_fv,        // writes v

  output reg         d_legacy,    // not handled by the datapath path above

  // ---- fields the pipelined core needs. the multi-cycle core ignores these,
  // so they can be filled in for every group without disturbing it ----
  output reg  [1:0]  d_mem,       // none / load / store
  output reg  [2:0]  d_msize,
  output reg         d_msigned,
  output reg         d_st_c,      // store data comes from port c, not port a
  output reg  [2:0]  d_br,        // branch kind
  output reg  [3:0]  d_cond,
  output reg  [31:0] d_boff,      // sign extended branch offset
  output reg         d_is32,      // 32-bit thumb, needs a second halfword
  output reg         d_esc,       // escape to the multi-cycle sequencer

  // link register write, for bl and blx. separate from d_wb because those
  // write r14 while the branch target comes from somewhere else entirely
  output reg         d_link,
  // multi register transfer, run by the sequencer rather than the pipeline
  output reg         d_multi,
  output reg         d_mload,
  output reg  [7:0]  d_mlist,
  output reg         d_mextra,    // push lr / pop pc
  output reg         d_mstack,    // push/pop form: sp is the base, not rn

  // system register access, msr and mrs
  output reg  [1:0]  d_sys,
  output reg  [7:0]  d_sysm,

  // cps, which is the only way thread code masks interrupts
  output reg         d_cps,
  output reg         d_cps_val
);

  localparam [1:0] SYS_NONE = 2'd0;
  localparam [1:0] SYS_MSR  = 2'd1;
  localparam [1:0] SYS_MRS  = 2'd2;

  localparam [1:0] MEM_NONE  = 2'd0;
  localparam [1:0] MEM_LOAD  = 2'd1;
  localparam [1:0] MEM_STORE = 2'd2;

  localparam [2:0] BR_NONE   = 3'd0;
  localparam [2:0] BR_COND   = 3'd1;
  localparam [2:0] BR_UNCOND = 3'd2;
  localparam [2:0] BR_BL     = 3'd3;
  // an indirect branch takes its target from the datapath result, which is how
  // bx, blx and any write to r15 all become the same thing
  localparam [2:0] BR_IND    = 3'd4;

  localparam [2:0] SZ_BYTE = 3'd0;
  localparam [2:0] SZ_HALF = 3'd1;
  localparam [2:0] SZ_WORD = 3'd2;

  // ---- operand a sources ----
  localparam [2:0] OA_RA    = 3'd0;
  localparam [2:0] OA_RB    = 3'd1;
  localparam [2:0] OA_RC    = 3'd2;
  localparam [2:0] OA_SP    = 3'd3;
  localparam [2:0] OA_PC4   = 3'd4;   // pc + 4, for adr
  localparam [2:0] OA_ZERO  = 3'd5;

  // ---- operand b sources ----
  localparam [2:0] OB_RA    = 3'd0;
  localparam [2:0] OB_RB    = 3'd1;
  localparam [2:0] OB_RC    = 3'd2;
  localparam [2:0] OB_IMM   = 3'd3;
  localparam [2:0] OB_ZERO  = 3'd4;

  // ---- datapath ops ----
  localparam [4:0] OP_ADD   = 5'd0;
  localparam [4:0] OP_ADC   = 5'd1;
  localparam [4:0] OP_SUB   = 5'd2;   // a + ~b + 1
  localparam [4:0] OP_SBC   = 5'd3;   // a + ~b + c
  localparam [4:0] OP_AND   = 5'd4;
  localparam [4:0] OP_ORR   = 5'd5;
  localparam [4:0] OP_EOR   = 5'd6;
  localparam [4:0] OP_BIC   = 5'd7;
  localparam [4:0] OP_MVN   = 5'd8;
  localparam [4:0] OP_MOV   = 5'd9;
  localparam [4:0] OP_SHIFT = 5'd10;
  localparam [4:0] OP_MUL   = 5'd11;
  localparam [4:0] OP_SXTH  = 5'd12;
  localparam [4:0] OP_SXTB  = 5'd13;
  localparam [4:0] OP_UXTH  = 5'd14;
  localparam [4:0] OP_UXTB  = 5'd15;
  localparam [4:0] OP_REV   = 5'd16;
  localparam [4:0] OP_REV16 = 5'd17;
  localparam [4:0] OP_REVSH = 5'd18;

  localparam [1:0] SH_LSL = 2'd0;
  localparam [1:0] SH_LSR = 2'd1;
  localparam [1:0] SH_ASR = 2'd2;
  localparam [1:0] SH_ROR = 2'd3;

  // 010001 is the high register group, which names 4-bit registers; 11110 is
  // the 32-bit space, where msr takes rn from the first halfword; 1100 is
  // stmia/ldmia, whose base is inst[10:8]; the 8-bit immediate group and the
  // sp-relative loads and stores name their register in inst[10:8] too
  assign d_ra = (inst[15:11] == 5'b11110)  ? inst[3:0] :
                (inst[15:10] == 6'b010001) ? {inst[7], inst[2:0]} :
                                             {1'b0, inst[2:0]};
  assign d_rb = (inst[15:10] == 6'b010001) ? inst[6:3] :
                (inst[15:12] == 4'b1100)   ? {1'b0, inst[10:8]} :
                                             {1'b0, inst[5:3]};
  assign d_rc = ((inst[15:13] == 3'b001) || (inst[15:12] == 4'b1001))
                ? {1'b0, inst[10:8]} : {1'b0, inst[8:6]};

  always @* begin
    // defaults: decode nothing, defer to the old path. every group that sets
    // d_legacy low must set everything it depends on
    d_rd     = {1'b0, inst[2:0]};
    d_imm    = 32'd0;
    d_opa    = OA_RA;
    d_opb    = OB_RB;
    d_op     = OP_MOV;
    d_shop   = SH_LSL;
    d_sh_reg = 1'b0;
    d_wb     = 1'b0;
    d_fnz    = 1'b0;
    d_fc     = 1'b0;
    d_fv     = 1'b0;
    d_legacy = 1'b1;
    d_mem     = MEM_NONE;
    d_msize   = SZ_WORD;
    d_msigned = 1'b0;
    d_st_c    = 1'b0;
    d_br      = BR_NONE;
    d_cond    = inst[11:8];
    d_boff    = 32'd0;
    d_is32    = 1'b0;
    d_esc     = 1'b0;
    d_link    = 1'b0;
    d_multi   = 1'b0;
    d_mload   = 1'b0;
    d_mlist   = inst[7:0];
    d_mextra  = 1'b0;
    d_mstack  = 1'b0;
    d_sys     = SYS_NONE;
    d_sysm    = inst2[7:0];
    d_cps     = 1'b0;
    d_cps_val = inst[4];

    casez (inst[15:10])
      // ---- shift by immediate, add/sub register or 3-bit immediate ----
      6'b000???: begin
        if (inst[15:11] == 5'b00011) begin
          // add/sub, rd = rn op (rm | imm3)
          d_rd     = {1'b0, inst[2:0]};
          d_opa    = OA_RB;                       // rn
          d_opb    = inst[10] ? OB_IMM : OB_RC;   // imm3 or rm
          d_imm    = {29'd0, inst[8:6]};
          d_op     = inst[9] ? OP_SUB : OP_ADD;
          d_wb     = 1'b1;
          d_fnz    = 1'b1;
          d_fc     = 1'b1;
          d_fv     = 1'b1;
          d_legacy = 1'b0;
        end else if ((inst[12:11] == 2'b00) && (inst[10:6] == 5'd0)) begin
          // `lsls rd, rm, #0` is how thumb-1 spells `movs rd, rm`, and it is
          // one of the most common instructions a compiler emits. sending it
          // through the barrel shifter is pure cost: a shift by zero returns
          // the value unchanged and leaves the carry alone, which is exactly
          // what a mov does, so it is decoded as one. that keeps it off the
          // shifter, which is the deepest thing in the datapath and now takes
          // a second cycle
          d_rd     = {1'b0, inst[2:0]};
          d_opa    = OA_ZERO;
          d_opb    = OB_RB;                       // rm
          d_op     = OP_MOV;
          d_wb     = 1'b1;
          d_fnz    = 1'b1;
          d_legacy = 1'b0;
        end else begin
          // lsl/lsr/asr by immediate. lsr and asr encode 32 as 0
          d_rd     = {1'b0, inst[2:0]};
          d_opa    = OA_RB;                       // rm
          d_opb    = OB_IMM;
          d_op     = OP_SHIFT;
          d_shop   = (inst[12:11] == 2'b00) ? SH_LSL :
                     (inst[12:11] == 2'b01) ? SH_LSR : SH_ASR;
          d_imm    = ((inst[12:11] != 2'b00) && (inst[10:6] == 5'd0))
                     ? 32'd32 : {27'd0, inst[10:6]};
          d_wb     = 1'b1;
          d_fnz    = 1'b1;
          d_fc     = 1'b1;
          d_legacy = 1'b0;
        end
      end

      // ---- mov/cmp/add/sub 8-bit immediate ----
      6'b001???: begin
        d_rd     = {1'b0, inst[10:8]};
        d_opa    = OA_RC;
        d_opb    = OB_IMM;
        d_imm    = {24'd0, inst[7:0]};
        d_fnz    = 1'b1;
        d_legacy = 1'b0;
        case (inst[12:11])
          2'b00: begin  // mov
            d_op = OP_MOV;
            d_wb = 1'b1;
          end
          2'b01: begin  // cmp, flags only
            d_op  = OP_SUB;
            d_fc  = 1'b1;
            d_fv  = 1'b1;
          end
          2'b10: begin  // add
            d_op  = OP_ADD;
            d_wb  = 1'b1;
            d_fc  = 1'b1;
            d_fv  = 1'b1;
          end
          default: begin  // sub
            d_op  = OP_SUB;
            d_wb  = 1'b1;
            d_fc  = 1'b1;
            d_fv  = 1'b1;
          end
        endcase
      end

      // ---- data processing register ----
      6'b010000: begin
        d_rd     = {1'b0, inst[2:0]};
        d_opa    = OA_RA;                 // rd as source
        d_opb    = OB_RB;                 // rm
        d_wb     = 1'b1;
        d_fnz    = 1'b1;
        d_legacy = 1'b0;
        case (inst[9:6])
          4'h0: d_op = OP_AND;
          4'h1: d_op = OP_EOR;
          4'h2: begin d_op = OP_SHIFT; d_shop = SH_LSL; d_sh_reg = 1'b1;
                      d_fc = 1'b1; end
          4'h3: begin d_op = OP_SHIFT; d_shop = SH_LSR; d_sh_reg = 1'b1;
                      d_fc = 1'b1; end
          4'h4: begin d_op = OP_SHIFT; d_shop = SH_ASR; d_sh_reg = 1'b1;
                      d_fc = 1'b1; end
          4'h5: begin d_op = OP_ADC; d_fc = 1'b1; d_fv = 1'b1; end
          4'h6: begin d_op = OP_SBC; d_fc = 1'b1; d_fv = 1'b1; end
          4'h7: begin d_op = OP_SHIFT; d_shop = SH_ROR; d_sh_reg = 1'b1;
                      d_fc = 1'b1; end
          4'h8: begin d_op = OP_AND; d_wb = 1'b0; end          // tst
          4'h9: begin d_op = OP_SUB; d_opa = OA_ZERO;          // rsb rd, rm, #0
                      d_opb = OB_RB; d_fc = 1'b1; d_fv = 1'b1; end
          4'ha: begin d_op = OP_SUB; d_wb = 1'b0;              // cmp
                      d_fc = 1'b1; d_fv = 1'b1; end
          4'hb: begin d_op = OP_ADD; d_wb = 1'b0;              // cmn
                      d_fc = 1'b1; d_fv = 1'b1; end
          4'hc: d_op = OP_ORR;
          4'hd: d_op = OP_MUL;
          4'he: d_op = OP_BIC;
          default: d_op = OP_MVN;
        endcase
      end

      // ---- special data processing and branch exchange ----
      6'b010001: begin
        d_rd = {inst[7], inst[2:0]};
        case (inst[9:8])
          2'b00: begin              // add rd, rm, no flags
            d_opa = OA_RA;
            d_opb = OB_RB;
            d_op  = OP_ADD;
            d_wb  = 1'b1;
          end
          2'b01: begin              // cmp rd, rm, flags only
            d_opa = OA_RA;
            d_opb = OB_RB;
            d_op  = OP_SUB;
            d_fnz = 1'b1;
            d_fc  = 1'b1;
            d_fv  = 1'b1;
          end
          2'b10: begin              // mov rd, rm, no flags
            d_opa = OA_ZERO;
            d_opb = OB_RB;
            d_op  = OP_MOV;
            d_wb  = 1'b1;
          end
          default: begin            // bx / blx rm
            d_opa  = OA_ZERO;
            d_opb  = OB_RB;
            d_op   = OP_MOV;
            d_br   = BR_IND;
            d_link = inst[7];       // blx writes lr
            // an exception return is a bx to a magic lr value, which the
            // pipeline cannot do: leave that to the sequencer
            d_esc  = 1'b0;
          end
        endcase
      end

      // ---- ldr literal: rt = [pc_align4 + imm8*4] ----
      6'b01001?: begin
        d_rd    = {1'b0, inst[10:8]};
        d_opa   = OA_PC4;
        d_opb   = OB_IMM;
        d_imm   = {22'd0, inst[7:0], 2'b00};
        d_mem   = MEM_LOAD;
        d_msize = SZ_WORD;
        d_wb    = 1'b1;
      end

      // ---- load/store register offset ----
      6'b0101??: begin
        d_opa = OA_RB;                 // rn
        d_opb = OB_RC;                 // rm
        d_rd  = {1'b0, inst[2:0]};     // rt
        case (inst[11:9])
          3'b000: begin d_mem = MEM_STORE; d_msize = SZ_WORD; end
          3'b001: begin d_mem = MEM_STORE; d_msize = SZ_HALF; end
          3'b010: begin d_mem = MEM_STORE; d_msize = SZ_BYTE; end
          3'b011: begin d_mem = MEM_LOAD;  d_msize = SZ_BYTE;
                        d_msigned = 1'b1; d_wb = 1'b1; end
          3'b100: begin d_mem = MEM_LOAD;  d_msize = SZ_WORD; d_wb = 1'b1; end
          3'b101: begin d_mem = MEM_LOAD;  d_msize = SZ_HALF; d_wb = 1'b1; end
          3'b110: begin d_mem = MEM_LOAD;  d_msize = SZ_BYTE; d_wb = 1'b1; end
          default: begin d_mem = MEM_LOAD; d_msize = SZ_HALF;
                         d_msigned = 1'b1; d_wb = 1'b1; end
        endcase
      end

      // ---- load/store word and byte, immediate offset ----
      6'b011???: begin
        d_opa   = OA_RB;
        d_opb   = OB_IMM;
        d_rd    = {1'b0, inst[2:0]};
        d_msize = inst[12] ? SZ_BYTE : SZ_WORD;
        // the word form scales the offset by four, the byte form not at all
        d_imm   = inst[12] ? {27'd0, inst[10:6]}
                           : {25'd0, inst[10:6], 2'b00};
        d_mem   = inst[11] ? MEM_LOAD : MEM_STORE;
        d_wb    = inst[11];
      end

      // ---- load/store halfword, immediate offset ----
      6'b1000??: begin
        d_opa   = OA_RB;
        d_opb   = OB_IMM;
        d_rd    = {1'b0, inst[2:0]};
        d_msize = SZ_HALF;
        d_imm   = {26'd0, inst[10:6], 1'b0};
        d_mem   = inst[11] ? MEM_LOAD : MEM_STORE;
        d_wb    = inst[11];
      end

      // ---- load/store sp relative ----
      6'b1001??: begin
        d_opa   = OA_SP;
        d_opb   = OB_IMM;
        d_rd    = {1'b0, inst[10:8]};
        d_imm   = {22'd0, inst[7:0], 2'b00};
        d_msize = SZ_WORD;
        d_mem   = inst[11] ? MEM_LOAD : MEM_STORE;
        d_wb    = inst[11];
        d_st_c  = 1'b1;                // rt is inst[10:8], which is port c
      end

      // ---- adr and add sp, immediate ----
      6'b1010??: begin
        d_rd  = {1'b0, inst[10:8]};
        d_opa = inst[11] ? OA_SP : OA_PC4;
        d_opb = OB_IMM;
        d_imm = {22'd0, inst[7:0], 2'b00};
        d_op  = OP_ADD;
        d_wb  = 1'b1;
      end

      // ---- conditional branch, svc and udf ----
      6'b1101??: begin
        if (inst[11:8] == 4'hf || inst[11:8] == 4'he) begin
          d_esc = 1'b1;                // svc, udf
        end else begin
          d_br   = BR_COND;
          d_cond = inst[11:8];
          d_boff = {{23{inst[7]}}, inst[7:0], 1'b0};
        end
      end

      // ---- unconditional branch ----
      6'b11100?: begin
        d_br   = BR_UNCOND;
        d_boff = {{20{inst[10]}}, inst[10:0], 1'b0};
      end

      // ---- 32-bit forms ----
      6'b11110?: begin
        d_is32 = 1'b1;
        if (inst2[14] && inst2[12]) begin
          // bl: the offset is split across both halfwords, with j1/j2 xored
          // against s to make the sign extension work over the whole range
          d_br   = BR_UNCOND;
          d_link = 1'b1;
          d_boff = {{7{inst[10]}},
                    inst[10],
                    ~(inst2[13] ^ inst[10]),
                    ~(inst2[11] ^ inst[10]),
                    inst[9:0], inst2[10:0], 1'b0};
        end else if ((inst[15:4] == 12'hf3e) && (inst2[15:14] == 2'b10)) begin
          // mrs rd, sysm
          d_sys = SYS_MRS;
          d_rd  = inst2[11:8];
          d_wb  = 1'b1;
        end else if ((inst[15:4] == 12'hf38) && (inst2[15:14] == 2'b10)) begin
          // msr sysm, rn. these are how an rtos reaches psp and control, so
          // leaving them as nops silently breaks any context switch
          d_sys = SYS_MSR;
          d_opa = OA_ZERO;
          d_opb = OB_RA;
          d_op  = OP_MOV;
        end else begin
          // dsb, dmb, isb and anything else 32-bit: nothing to do on a core
          // with no store buffer and no cache. it still consumes two halfwords
        end
      end

      // ---- stmia and ldmia ----
      6'b1100??: begin
        d_multi  = 1'b1;
        d_mload  = inst[11];
        d_mlist  = inst[7:0];
        d_rd     = {1'b0, inst[10:8]};
        d_mstack = 1'b0;
        d_esc    = 1'b1;
      end

      // ---- miscellaneous 16-bit ----
      //
      // push and pop are told apart by inst[11:9], 010 and 110. slicing any
      // other field gets pop wrong, which is a return instruction, so nothing
      // compiled by a c toolchain runs
      6'b1011??: begin
        if (inst[11:8] == 4'b0000) begin
          // add/sub sp, immediate. the 7-bit immediate is scaled by four
          d_opa = OA_SP;
          d_opb = OB_IMM;
          d_imm = {23'd0, inst[6:0], 2'b00};
          d_op  = inst[7] ? OP_SUB : OP_ADD;
          d_rd  = 4'd13;
          d_wb  = 1'b1;
        end else if (inst[11:9] == 3'b010) begin
          // push {list, lr}
          d_multi  = 1'b1;
          d_mload  = 1'b0;
          d_mlist  = inst[7:0];
          d_mextra = inst[8];
          d_mstack = 1'b1;
          d_esc    = 1'b1;
        end else if (inst[11:9] == 3'b110) begin
          // pop {list, pc}
          d_multi  = 1'b1;
          d_mload  = 1'b1;
          d_mlist  = inst[7:0];
          d_mextra = inst[8];
          d_mstack = 1'b1;
          d_esc    = 1'b1;
        end else if (inst[11:8] == 4'b0010) begin
          // sxth/sxtb/uxth/uxtb, all rd = f(rm)
          d_opa = OA_ZERO;
          d_opb = OB_RB;
          d_rd  = {1'b0, inst[2:0]};
          d_wb  = 1'b1;
          case (inst[7:6])
            2'b00:   d_op = OP_SXTH;
            2'b01:   d_op = OP_SXTB;
            2'b10:   d_op = OP_UXTH;
            default: d_op = OP_UXTB;
          endcase
        end else if (inst[11:8] == 4'b1010) begin
          // rev/rev16/revsh
          d_opa = OA_ZERO;
          d_opb = OB_RB;
          d_rd  = {1'b0, inst[2:0]};
          d_wb  = 1'b1;
          case (inst[7:6])
            2'b00:   d_op = OP_REV;
            2'b01:   d_op = OP_REV16;
            default: d_op = OP_REVSH;
          endcase
        end else if (inst[11:5] == 7'b0110011) begin
          // cps: inst[4] is the im bit, 1 disables interrupts
          d_cps = 1'b1;
        end else if (inst[15:8] == 8'hbf) begin
          // ---- the hint space: nop, yield, wfe, wfi, sev ----
          //
          // executed as a nop, which armv6-m permits for all of them and
          // requires for NOP itself. this is not a corner: the toolchain emits
          // `nop` for alignment padding and every idle loop ends in `wfi`, and
          // escaping them sent the core to ST_HALTED with `unsupported` set,
          // or to ST_STOPPED with no debugger attached. it survived this long
          // only because blink and hello are small enough that gcc never
          // needed the padding.
          //
          // the defaults above are already inert -- no writeback, no memory,
          // no branch, no flags -- so there is nothing to do but decline to
          // escape. d_legacy clears so the multi-cycle core takes the same
          // path rather than falling through to its casez
          d_legacy = 1'b0;
        end else begin
          // bkpt, and anything else in this space that is not implemented
          d_esc = 1'b1;
        end
      end

      default: begin
        d_esc    = 1'b1;
        d_legacy = 1'b1;
      end
    endcase
  end

endmodule

`default_nettype wire

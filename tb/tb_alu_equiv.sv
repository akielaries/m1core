`timescale 1ns/1ps

// m1core_alu against an independent model
//
// the datapath is four function units that every instruction drives, and the
// core selects between them with a code decode worked out a cycle earlier. so
// each unit has to be right over its own op group on its own, without a mux in
// front of it to hide anything, and that is what this checks.
//
// the shifter is the part that needs it. it is a funnel: left shifts reach it
// by reversing in and out, since a << m is rev(rev(a) >> m), and the carry rule
// falls out of the same identity because lsl's carry a[32-m] is exactly
// rev(a)[m-1], the bit lsr reports. the output classes in front of it -- amount
// zero, in range, exactly 32, past the sign bit, rotate by a multiple of 32 --
// are decided in parallel with the barrel rather than behind it. that is a
// clever encoding of the architecture rather than a transcription of it.
//
// the model below is written straight from the armv6-m pseudocode for LSL_C,
// LSR_C, ASR_C and ROR_C, shares no structure with the implementation, and
// every case of both is compared.

module tb_alu_equiv;

  localparam [4:0] OP_ADD = 5'd0,  OP_ADC = 5'd1,  OP_SUB = 5'd2,
                   OP_SBC = 5'd3,  OP_AND = 5'd4,  OP_ORR = 5'd5,
                   OP_EOR = 5'd6,  OP_BIC = 5'd7,  OP_MVN = 5'd8,
                   OP_MOV = 5'd9,  OP_SHIFT = 5'd10, OP_MUL = 5'd11,
                   OP_SXTH = 5'd12, OP_SXTB = 5'd13, OP_UXTH = 5'd14,
                   OP_UXTB = 5'd15, OP_REV = 5'd16, OP_REV16 = 5'd17,
                   OP_REVSH = 5'd18;

  localparam [1:0] SH_LSL = 2'd0, SH_LSR = 2'd1, SH_ASR = 2'd2, SH_ROR = 2'd3;

  reg  [4:0]  op;
  reg  [1:0]  shop;
  reg  [31:0] a, b;
  reg  [7:0]  shamt;
  reg         cin;

  wire [31:0] sum_res, sh_res, logic_res, xform_res;
  wire        sum_c, sum_v, sh_c;

  m1core_alu dut (
    .op(op), .shop(shop), .a(a), .b(b), .shamt(shamt), .cin(cin),
    .sum_res(sum_res), .sum_c(sum_c), .sum_v(sum_v),
    .sh_res(sh_res),   .sh_c(sh_c),
    .logic_res(logic_res), .xform_res(xform_res)
  );

  // ---- the model ----

  // armv6-m shift with carry. the amount is the register-controlled form, so
  // it runs past 32 and the out-of-range rules matter
  function automatic [32:0] ref_shift(input [1:0] sop, input [31:0] v,
                                      input [7:0] amt, input ci);
    reg [31:0] r;
    reg        co;
    integer    n, m;
    begin
      n = amt;
      if (n == 0) begin
        r  = v;
        co = ci;
      end else begin
        case (sop)
          SH_LSL: begin
            if (n < 32)       begin r = v << n;  co = v[32 - n]; end
            else if (n == 32) begin r = 32'd0;   co = v[0];      end
            else              begin r = 32'd0;   co = 1'b0;      end
          end
          SH_LSR: begin
            if (n < 32)       begin r = v >> n;  co = v[n - 1];  end
            else if (n == 32) begin r = 32'd0;   co = v[31];     end
            else              begin r = 32'd0;   co = 1'b0;      end
          end
          SH_ASR: begin
            if (n < 32) begin r = $signed(v) >>> n; co = v[n - 1]; end
            else        begin r = {32{v[31]}};      co = v[31];    end
          end
          default: begin                       // ror, by n mod 32
            m = n % 32;
            if (m == 0) begin r = v; co = v[31]; end
            else begin
              r  = (v >> m) | (v << (32 - m));
              co = v[m - 1];                   // which is r[31]
            end
          end
        endcase
      end
      ref_shift = {co, r};
    end
  endfunction

  function automatic [33:0] ref_sum(input [4:0] o, input [31:0] va,
                                    input [31:0] vb, input ci);
    reg [32:0] s;
    reg [31:0] addb;
    reg        aci, ovf;
    begin
      addb = (o == OP_SUB || o == OP_SBC) ? ~vb : vb;
      aci  = (o == OP_ADD) ? 1'b0 : (o == OP_SUB) ? 1'b1 : ci;
      s    = {1'b0, va} + {1'b0, addb} + {32'd0, aci};
      ovf  = (va[31] == addb[31]) && (s[31] != va[31]);
      ref_sum = {ovf, s};
    end
  endfunction

  function automatic [31:0] ref_logic(input [4:0] o, input [31:0] va,
                                      input [31:0] vb);
    begin
      case (o)
        OP_AND:  ref_logic = va & vb;
        OP_ORR:  ref_logic = va | vb;
        OP_EOR:  ref_logic = va ^ vb;
        OP_BIC:  ref_logic = va & ~vb;
        OP_MVN:  ref_logic = ~vb;
        default: ref_logic = vb;               // mov
      endcase
    end
  endfunction

  function automatic [31:0] ref_xform(input [4:0] o, input [31:0] vb);
    begin
      case (o)
        OP_SXTH:  ref_xform = {{16{vb[15]}}, vb[15:0]};
        OP_SXTB:  ref_xform = {{24{vb[7]}},  vb[7:0]};
        OP_UXTH:  ref_xform = {16'd0, vb[15:0]};
        OP_UXTB:  ref_xform = {24'd0, vb[7:0]};
        OP_REV:   ref_xform = {vb[7:0], vb[15:8], vb[23:16], vb[31:24]};
        OP_REV16: ref_xform = {vb[23:16], vb[31:24], vb[7:0], vb[15:8]};
        default:  ref_xform = {{16{vb[7]}}, vb[7:0], vb[15:8]};   // revsh
      endcase
    end
  endfunction

  reg [31:0] vals [0:23];
  reg [32:0] esh;
  reg [33:0] esum;
  reg [31:0] elog, exf;
  integer    i, j, k, s, ci_i, bad, checks;

  task automatic bad_case(input [255:0] what);
    begin
      bad = bad + 1;
      if (bad <= 10) begin
        $display("FAIL %0s  op=%0d shop=%0d a=%08x b=%08x amt=%0d cin=%b",
                 what, op, shop, a, b, shamt, cin);
      end
    end
  endtask

  initial begin
    // the awkward values: signs, carries out of every boundary, alternating
    // patterns that make a reversed shifter disagree with a straight one
    vals[0]  = 32'h00000000; vals[1]  = 32'hffffffff; vals[2]  = 32'h80000000;
    vals[3]  = 32'h00000001; vals[4]  = 32'h7fffffff; vals[5]  = 32'haaaaaaaa;
    vals[6]  = 32'h55555555; vals[7]  = 32'hdeadbeef; vals[8]  = 32'h0000ffff;
    vals[9]  = 32'hffff0000; vals[10] = 32'h00008000; vals[11] = 32'h00010000;
    vals[12] = 32'h12345678; vals[13] = 32'h87654321; vals[14] = 32'hfffffffe;
    vals[15] = 32'h00000002; vals[16] = 32'h40000000; vals[17] = 32'hc0000000;
    vals[18] = 32'h0000000f; vals[19] = 32'hf0000000; vals[20] = 32'h01234567;
    vals[21] = 32'h89abcdef; vals[22] = 32'h3fffffff; vals[23] = 32'hbfffffff;

    bad    = 0;
    checks = 0;

    // ---- the shifter: every op, every amount through the out-of-range
    // rules, every value, both carry ins ----
    op = OP_SHIFT;
    b  = 32'd0;
    for (s = 0; s < 4; s = s + 1) begin
      shop = s[1:0];
      for (k = 0; k < 24; k = k + 1) begin
        a = vals[k];
        for (j = 0; j <= 259; j = j + 1) begin
          shamt = j[7:0];
          for (ci_i = 0; ci_i < 2; ci_i = ci_i + 1) begin
            cin = ci_i[0];
            #1;
            esh    = ref_shift(shop, a, shamt, cin);
            checks = checks + 1;
            if (sh_res !== esh[31:0] || sh_c !== esh[32]) begin
              bad_case("shifter");
            end
          end
        end
      end
    end

    // ---- the adder, over its four ops ----
    shamt = 8'd0;
    for (i = OP_ADD; i <= OP_SBC; i = i + 1) begin
      op = i[4:0];
      for (k = 0; k < 24; k = k + 1) begin
        a = vals[k];
        for (j = 0; j < 24; j = j + 1) begin
          b = vals[j];
          for (ci_i = 0; ci_i < 2; ci_i = ci_i + 1) begin
            cin = ci_i[0];
            #1;
            esum   = ref_sum(op, a, b, cin);
            checks = checks + 1;
            if (sum_res !== esum[31:0] || sum_c !== esum[32] ||
                sum_v !== esum[33]) begin
              bad_case("adder");
            end
          end
        end
      end
    end

    // ---- the logic unit, over its six ops ----
    for (i = OP_AND; i <= OP_MOV; i = i + 1) begin
      op = i[4:0];
      for (k = 0; k < 24; k = k + 1) begin
        a = vals[k];
        for (j = 0; j < 24; j = j + 1) begin
          b = vals[j];
          #1;
          elog   = ref_logic(op, a, b);
          checks = checks + 1;
          if (logic_res !== elog) begin
            bad_case("logic");
          end
        end
      end
    end

    // ---- the transform unit, over its seven ops ----
    for (i = OP_SXTH; i <= OP_REVSH; i = i + 1) begin
      op = i[4:0];
      a  = 32'hdeadbeef;
      for (j = 0; j < 24; j = j + 1) begin
        b = vals[j];
        #1;
        exf    = ref_xform(op, b);
        checks = checks + 1;
        if (xform_res !== exf) begin
          bad_case("xform");
        end
      end
    end

    if (bad == 0) begin
      $display("ok   alu matches the model    %0d cases", checks);
      $display("");
      $display("PASS");
    end else begin
      $display("FAIL %0d of %0d cases disagree", bad, checks);
      $display("");
      $display("FAIL");
    end
    $finish;
  end

endmodule

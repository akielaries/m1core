`default_nettype none

// m1core execute datapath
//
// one adder, one shifter, one logic unit, one transform unit. every
// instruction drives these and nothing builds its own arithmetic.
//
// ---- why there is no result mux in here ----
//
// there was, a nineteen-way case on op, and place and route made it four
// levels of lut. the core then muxed that against the multiplier, the system
// registers and the load data, which was two more. seven levels of mux hanging
// off the end of the adder and the shifter, and the timing report put 7.13 ns
// of a 16.34 ns path in them.
//
// the four results come out separately instead and the core selects once,
// together with everything else it has to choose between, from a code decode
// worked out a cycle earlier. one mux, not three in series. it makes this
// module a bank of function units rather than an alu, which is what it always
// was.
//
// OP_MUL is deliberately absent. the 32x32 multiply maps to a dsp block whose
// output would sit in that mux, and the mux is on the forwarding bypass, so
// every instruction's result-to-operand path would wait on the multiplier. the
// core computes it in its own cycle instead, see mul_q
//
// the shifter is a funnel. left shifts reach it by reversing in and out, since
// a << m is rev(rev(a) >> m), and the carry rule falls out of the same
// identity because lsl's carry a[32-m] is exactly rev(a)[m-1], the bit lsr
// reports. `make -C sim aluequiv` checks every output of this module against a
// model written from the armv6-m pseudocode; none of the above is safe to
// change on inspection alone.

module m1core_alu (
  input  wire [4:0]  op,
  input  wire [1:0]  shop,
  input  wire [31:0] a,
  input  wire [31:0] b,
  input  wire [7:0]  shamt,
  input  wire        cin,

  // add, adc, sub, sbc. subtract is a + ~b + 1 and the carry in carries the
  // borrow for sbc, so nothing else needs its own arithmetic
  output wire [31:0] sum_res,
  output wire        sum_c,
  output wire        sum_v,

  // lsl, lsr, asr, ror, by immediate or by register
  output wire [31:0] sh_res,
  output wire        sh_c,

  // and, orr, eor, bic, mvn, mov
  output reg  [31:0] logic_res,

  // sxth, sxtb, uxth, uxtb, rev, rev16, revsh: permutations of b
  output reg  [31:0] xform_res
);

  localparam [4:0] OP_ADD = 5'd0;
  localparam [4:0] OP_ADC = 5'd1;
  localparam [4:0] OP_SUB = 5'd2;
  localparam [4:0] OP_SBC = 5'd3;
  localparam [4:0] OP_AND = 5'd4;
  localparam [4:0] OP_ORR = 5'd5;
  localparam [4:0] OP_EOR = 5'd6;
  localparam [4:0] OP_BIC = 5'd7;
  localparam [4:0] OP_MVN = 5'd8;
  localparam [4:0] OP_MOV = 5'd9;
  localparam [4:0] OP_SHIFT = 5'd10;
  localparam [4:0] OP_MUL = 5'd11;
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

  function automatic [31:0] rev32(input [31:0] v);
    integer i;
    begin
      for (i = 0; i < 32; i = i + 1) begin
        rev32[i] = v[31 - i];
      end
    end
  endfunction

  // ---- which of the six answers the shifter gives ----
  //
  // this used to be a five-deep priority chain of 33-bit ternaries hanging off
  // the funnel output, and it was four levels of the longest path in the core.
  // every one of these conditions is known from the op and the amount alone,
  // so the class is decided in parallel with the barrel and the barrel result
  // meets one flat mux instead of five chained ones
  localparam [2:0] SHC_PASS  = 3'd0;   // amount zero, value and carry unchanged
  localparam [2:0] SHC_LEFT  = 3'd1;   // in range, reversed back out
  localparam [2:0] SHC_RIGHT = 3'd2;   // in range, straight out
  localparam [2:0] SHC_ROR0  = 3'd3;   // rotate by a multiple of 32
  localparam [2:0] SHC_ASRX  = 3'd4;   // arithmetic shift past the sign bit
  localparam [2:0] SHC_E32   = 3'd5;   // exactly 32: one bit survives as carry
  localparam [2:0] SHC_ZERO  = 3'd6;   // shifted out entirely

  // flat rather than a priority chain: the six cases are disjoint by
  // construction, so each one is an and of two cheap predicates and the class
  // settles in parallel with the barrel instead of behind a chain of ternaries
  function automatic [2:0] shift_class(input [1:0] sop, input [7:0] amt);
    reg amt0, in_range, is_32, m0, ror, asr, lsl;
    begin
      amt0     = (amt == 8'd0);
      in_range = (amt[7:5] == 3'd0) && !amt0;      // 1..31
      is_32    = (amt == 8'd32);
      m0       = (amt[4:0] == 5'd0);
      ror      = (sop == SH_ROR);
      asr      = (sop == SH_ASR);
      lsl      = (sop == SH_LSL);
      case (1'b1)
        amt0:                     shift_class = SHC_PASS;
        ror:                      shift_class = m0 ? SHC_ROR0 : SHC_RIGHT;
        in_range:                 shift_class = lsl ? SHC_LEFT : SHC_RIGHT;
        asr:                      shift_class = SHC_ASRX;
        is_32:                    shift_class = SHC_E32;
        default:                  shift_class = SHC_ZERO;
      endcase
    end
  endfunction

  function automatic [32:0] do_shift(input [1:0] sop, input [31:0] v,
                                     input [7:0] amt, input ci);
    reg [31:0] sin;
    reg [31:0] sres;
    reg [63:0] funnel;
    reg [63:0] fsh;
    reg [4:0]  m;
    reg        co;
    begin
      m   = amt[4:0];
      sin = (sop == SH_LSL) ? rev32(v) : v;
      case (sop)
        SH_ASR:  funnel = {{32{v[31]}}, sin};
        SH_ROR:  funnel = {sin, sin};
        default: funnel = {32'd0, sin};
      endcase
      fsh  = funnel >> m;
      sres = fsh[31:0];
      co   = (m == 5'd0) ? ci : sin[m - 5'd1];
      case (shift_class(sop, amt))
        SHC_LEFT:  do_shift = {co, rev32(sres)};
        SHC_RIGHT: do_shift = {co, sres};
        SHC_ROR0:  do_shift = {v[31], v};
        SHC_ASRX:  do_shift = {v[31], {32{v[31]}}};
        SHC_E32:   do_shift = {(sop == SH_LSL) ? v[0] : v[31], 32'd0};
        SHC_ZERO:  do_shift = {1'b0, 32'd0};
        default:   do_shift = {ci, v};          // SHC_PASS
      endcase
    end
  endfunction

  // ---- the adder ----
  wire        sub  = (op == OP_SUB) || (op == OP_SBC);
  wire [31:0] addb = sub ? ~b : b;
  wire        addc_in = (op == OP_ADD) ? 1'b0 :
                        (op == OP_SUB) ? 1'b1 : cin;
  wire [32:0] sum  = {1'b0, a} + {1'b0, addb} + {32'd0, addc_in};

  assign sum_res = sum[31:0];
  assign sum_c   = sum[32];
  assign sum_v   = (a[31] == addb[31]) && (sum[31] != a[31]);

  // ---- the shifter ----
  wire [32:0] sh = do_shift(shop, a, shamt, cin);

  assign sh_res = sh[31:0];
  assign sh_c   = sh[32];

  // ---- the logic unit ----
  //
  // the six op codes are 4..9, whose low three bits are 4,5,6,7,0,1 and so are
  // distinct: selecting on op[2:0] keeps this one lut deep per bit instead of
  // making it a nineteen-way compare against the whole op
  always @* begin
    case (op[2:0])
      3'd4:    logic_res = a & b;         // and
      3'd5:    logic_res = a | b;         // orr
      3'd6:    logic_res = a ^ b;         // eor
      3'd7:    logic_res = a & ~b;        // bic
      3'd0:    logic_res = ~b;            // mvn
      default: logic_res = b;             // mov
    endcase
  end

  // ---- the transform unit ----
  //
  // codes 12..18, low three bits 4,5,6,7,0,1,2, distinct again. every one of
  // these is a permutation or a sign extension of b, so each output bit picks
  // between a handful of input bits and the whole unit is shallow
  always @* begin
    case (op[2:0])
      3'd4:    xform_res = {{16{b[15]}}, b[15:0]};                 // sxth
      3'd5:    xform_res = {{24{b[7]}},  b[7:0]};                  // sxtb
      3'd6:    xform_res = {16'd0, b[15:0]};                       // uxth
      3'd7:    xform_res = {24'd0, b[7:0]};                        // uxtb
      3'd0:    xform_res = {b[7:0], b[15:8], b[23:16], b[31:24]};  // rev
      3'd1:    xform_res = {b[23:16], b[31:24], b[7:0], b[15:8]};  // rev16
      default: xform_res = {{16{b[7]}}, b[7:0], b[15:8]};          // revsh
    endcase
  end

endmodule

`default_nettype wire

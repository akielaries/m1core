`default_nettype none

// m1core instruction fetch unit
//
// the 3-stage core needs an instruction every cycle, and the multi-cycle core
// spent two cycles per fetch because it dropped bus_req after each grant and
// then waited for it again. it does not have to: ahb_arb grants combinationally
// (m1_gnt = m1_req && !m0_req && hready) and ahb_sram starts the read in the
// address phase, so holding bus_req high issues one access per cycle and the
// data arrives on the following cycle. this unit does that.
//
// fetches are 32 bits, which is two thumb instructions per access. that halves
// the bus pressure, and it matters because fetch and load/store share a single
// ahb master: a data access has to win, and fetch has to survive losing.
//
// the queue holds halfwords rather than words so the decode stage never deals
// with alignment, and a 32-bit thumb instruction is just two pops.

module m1core_fetch #(
  parameter DEPTH = 8                   // halfwords, must be a power of two
) (
  input  wire        clk,
  input  wire        rst_n,

  // redirect: taken branch, exception entry, debug resume
  input  wire        redirect,
  input  wire [31:0] redirect_pc,

  // stop issuing (halted, or the pipeline is draining for a complex op)
  input  wire        stall,

  // bus master, shares the arbiter with the load/store unit. data accesses are
  // older than any fetch, so they take the bus and hold_off goes high
  input  wire        hold_off,
  output wire        f_req,
  output wire [31:0] f_addr,
  input  wire        f_gnt,
  input  wire [31:0] f_rdata,

  // to decode. pc is the address of inst, which decode needs for pc-relative
  // forms and execute needs for the return address
  output wire        f_valid,
  output wire [15:0] f_inst,
  output wire [31:0] f_pc,
  input  wire        f_pop,
  input  wire        f_pop2,      // take two, for a 32-bit thumb instruction
  output wire [15:0] f_inst2,     // the halfword after the head

  // enough room queued to pop two halfwords, so a 32-bit instruction does not
  // have to straddle a stall
  output wire        f_valid2
);

  localparam AW = (DEPTH <= 2)  ? 1 :
                  (DEPTH <= 4)  ? 2 :
                  (DEPTH <= 8)  ? 3 : 4;

  reg [15:0] q_data [0:DEPTH-1];
  reg [31:0] q_pc   [0:DEPTH-1];
  reg [AW:0] q_head, q_tail;            // one extra bit distinguishes full

  wire [AW:0] q_count = q_tail - q_head;
  wire        q_empty = (q_count == 0);

  // the address the next fetch would cover. word aligned: a redirect to an odd
  // halfword fetches the containing word and discards the low half
  reg [31:0] pc_f;
  reg        drop_lo;

  // an access is in the address phase and another in the data phase at the
  // same time. that overlap is the entire point of the ahb pipeline, and not
  // taking it is what cost the multi-cycle core two cycles per fetch: it held
  // off the next request until the previous one had returned
  reg        infl_v;
  reg [31:0] infl_pc;
  reg        infl_drop;

  localparam [AW:0] DEPTH_V = DEPTH[AW:0];
  wire [AW:0] q_space = DEPTH_V - q_count;

  // write pointers, AW bits wide: the extra bit of q_tail only exists to tell
  // full from empty and must not reach the array index
  wire [AW-1:0] w0 = q_tail[AW-1:0];
  wire [AW-1:0] w1 = q_tail[AW-1:0] + 1'b1;

  // room for the two halfwords already in flight plus the two being asked for
  assign f_req  = !stall && !hold_off && !redirect && (q_space >= 4);
  assign f_addr = pc_f;
  wire issue    = f_req && f_gnt;

  assign f_valid  = !q_empty;
  assign f_valid2 = (q_count >= 2);
  assign f_inst   = q_data[q_head[AW-1:0]];
  assign f_pc     = q_pc[q_head[AW-1:0]];
  assign f_inst2  = q_data[q_head[AW-1:0] + 1'b1];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_head    <= {(AW+1){1'b0}};
      q_tail    <= {(AW+1){1'b0}};
      pc_f      <= 32'd0;
      drop_lo   <= 1'b0;
      infl_v    <= 1'b0;
      infl_pc   <= 32'd0;
      infl_drop <= 1'b0;
    end else if (redirect) begin
      q_head    <= {(AW+1){1'b0}};
      q_tail    <= {(AW+1){1'b0}};
      pc_f      <= {redirect_pc[31:2], 2'b00};
      drop_lo   <= redirect_pc[1];
      // clearing infl_v drops both the access whose data lands next cycle and
      // any data landing this cycle, since the push below is in the else arm
      infl_v    <= 1'b0;
    end else begin
      if (f_pop && !q_empty) begin
        q_head <= q_head + (f_pop2 ? 2'd2 : 2'd1);
      end

      infl_v    <= issue;
      infl_pc   <= f_addr;
      infl_drop <= drop_lo;
      if (issue) begin
        pc_f    <= f_addr + 32'd4;
        drop_lo <= 1'b0;
      end

      if (infl_v) begin
        if (!infl_drop) begin
          q_data[w0] <= f_rdata[15:0];
          q_pc  [w0] <= infl_pc;
          q_data[w1] <= f_rdata[31:16];
          q_pc  [w1] <= infl_pc + 32'd2;
          q_tail <= q_tail + 2'd2;
        end else begin
          q_data[w0] <= f_rdata[31:16];
          q_pc  [w0] <= infl_pc + 32'd2;
          q_tail <= q_tail + 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire

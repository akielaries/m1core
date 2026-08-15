`default_nettype none

// nvic, systick and the scb exception bits
//
// lives inside the ppb page, which forwards the relevant offsets here:
//   0x010 SYST_CSR   0x014 SYST_RVR   0x018 SYST_CVR   0x01c SYST_CALIB
//   0x100 NVIC_ISER  0x180 NVIC_ICER  0x200 NVIC_ISPR  0x280 NVIC_ICPR
//   0x400 NVIC_IPR0..7
//   0xd04 ICSR       0xd1c SHPR2      0xd20 SHPR3
//
// priority encoding used internally, smaller wins:
//   0        NMI
//   1        HardFault
//   2 + n    configurable priority n (0..3)
//   6        thread, no exception active
//
// armv6-m has two implemented priority bits, in the top of each 8 bit field,
// which is why the ipr and shpr registers only keep bits [7:6]

module m1core_nvic (
  input  wire        clk,
  input  wire        rst_n,

  // register access forwarded from the ppb
  input  wire        sel,
  input  wire [11:0] offset,
  input  wire        write,
  input  wire [31:0] wdata,
  output reg  [31:0] rdata,

  // external interrupt sources, irq 0..31 map to exceptions 16..47
  input  wire [31:0] irq_in,

  // highest priority exception that wants to run
  output wire        pend_valid,
  output wire [5:0]  pend_num,
  output wire [2:0]  pend_prio,

  // the cpu reports what it took and what it returned from
  input  wire        exc_taken,
  input  wire [5:0]  exc_taken_num
);

  localparam [5:0] EXC_SVCALL  = 6'd11;
  localparam [5:0] EXC_PENDSV  = 6'd14;
  localparam [5:0] EXC_SYSTICK = 6'd15;

  // ---------------------------------------------------------------------------
  // systick
  // ---------------------------------------------------------------------------
  reg [23:0] syst_reload;
  reg [23:0] syst_current;
  reg        syst_enable, syst_tickint, syst_clksource;
  reg        syst_countflag;
  reg        pend_systick;

  wire syst_wrap = syst_enable && (syst_current == 24'd0);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      syst_reload    <= 24'd0;
      syst_current   <= 24'd0;
      syst_enable    <= 1'b0;
      syst_tickint   <= 1'b0;
      syst_clksource <= 1'b1;
      syst_countflag <= 1'b0;
    end else begin
      if (sel && write && offset == 12'h010) begin
        syst_enable    <= wdata[0];
        syst_tickint   <= wdata[1];
        syst_clksource <= wdata[2];
      end else if (sel && write && offset == 12'h014) begin
        syst_reload <= wdata[23:0];
      end else if (sel && write && offset == 12'h018) begin
        // any write clears the counter and the count flag
        syst_current   <= 24'd0;
        syst_countflag <= 1'b0;
      end else if (syst_enable) begin
        if (syst_current == 24'd0) begin
          syst_current   <= syst_reload;
          syst_countflag <= 1'b1;
        end else begin
          syst_current <= syst_current - 24'd1;
        end
      end

      // reading csr clears the count flag
      if (sel && !write && offset == 12'h010) begin
        syst_countflag <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // pending and enable state
  // ---------------------------------------------------------------------------
  reg [31:0] irq_enable;
  reg [31:0] irq_pending;
  reg [31:0] irq_in_d;
  reg        pend_pendsv;
  reg        pend_svc;

  reg [1:0]  prio_irq [0:31];
  reg [1:0]  prio_svc, prio_pendsv, prio_systick;

  integer i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      irq_enable  <= 32'd0;
      irq_pending <= 32'd0;
      irq_in_d    <= 32'd0;
      pend_pendsv <= 1'b0;
      pend_svc    <= 1'b0;
      pend_systick <= 1'b0;
      prio_svc     <= 2'd0;
      prio_pendsv  <= 2'd0;
      prio_systick <= 2'd0;
      for (i = 0; i < 32; i = i + 1) begin
        prio_irq[i] <= 2'd0;
      end
    end else begin
      irq_in_d <= irq_in;

      // a rising edge on a source latches pending. level sources that stay
      // asserted re-pend after the handler clears them at the peripheral
      irq_pending <= irq_pending | (irq_in & ~irq_in_d);

      if (syst_wrap && syst_tickint) begin
        pend_systick <= 1'b1;
      end

      if (sel && write) begin
        case (offset)
          12'h100: irq_enable  <= irq_enable  |  wdata;
          12'h180: irq_enable  <= irq_enable  & ~wdata;
          12'h200: irq_pending <= irq_pending |  wdata;
          12'h280: irq_pending <= irq_pending & ~wdata;
          12'hd04: begin
            if (wdata[28]) pend_pendsv  <= 1'b1;   // PENDSVSET
            if (wdata[27]) pend_pendsv  <= 1'b0;   // PENDSVCLR
            if (wdata[26]) pend_systick <= 1'b1;   // PENDSTSET
            if (wdata[25]) pend_systick <= 1'b0;   // PENDSTCLR
          end
          12'hd1c: prio_svc <= wdata[31:30];
          12'hd20: begin
            prio_pendsv  <= wdata[23:22];
            prio_systick <= wdata[31:30];
          end
          default: begin
            if (offset[11:5] == 7'b0100000) begin      // 0x400..0x41c
              case (offset[4:2])
                3'd0: begin prio_irq[0] <= wdata[7:6];  prio_irq[1] <= wdata[15:14];
                            prio_irq[2] <= wdata[23:22]; prio_irq[3] <= wdata[31:30]; end
                3'd1: begin prio_irq[4] <= wdata[7:6];  prio_irq[5] <= wdata[15:14];
                            prio_irq[6] <= wdata[23:22]; prio_irq[7] <= wdata[31:30]; end
                3'd2: begin prio_irq[8] <= wdata[7:6];  prio_irq[9] <= wdata[15:14];
                            prio_irq[10] <= wdata[23:22]; prio_irq[11] <= wdata[31:30]; end
                3'd3: begin prio_irq[12] <= wdata[7:6]; prio_irq[13] <= wdata[15:14];
                            prio_irq[14] <= wdata[23:22]; prio_irq[15] <= wdata[31:30]; end
                3'd4: begin prio_irq[16] <= wdata[7:6]; prio_irq[17] <= wdata[15:14];
                            prio_irq[18] <= wdata[23:22]; prio_irq[19] <= wdata[31:30]; end
                3'd5: begin prio_irq[20] <= wdata[7:6]; prio_irq[21] <= wdata[15:14];
                            prio_irq[22] <= wdata[23:22]; prio_irq[23] <= wdata[31:30]; end
                3'd6: begin prio_irq[24] <= wdata[7:6]; prio_irq[25] <= wdata[15:14];
                            prio_irq[26] <= wdata[23:22]; prio_irq[27] <= wdata[31:30]; end
                default: begin prio_irq[28] <= wdata[7:6]; prio_irq[29] <= wdata[15:14];
                            prio_irq[30] <= wdata[23:22]; prio_irq[31] <= wdata[31:30]; end
              endcase
            end
          end
        endcase
      end

      // the cpu has taken an exception, so it stops being pending
      if (exc_taken) begin
        if (exc_taken_num == EXC_PENDSV) begin
          pend_pendsv <= 1'b0;
        end else if (exc_taken_num == EXC_SYSTICK) begin
          pend_systick <= 1'b0;
        end else if (exc_taken_num == EXC_SVCALL) begin
          pend_svc <= 1'b0;
        end else if (exc_taken_num >= 6'd16) begin
          irq_pending[exc_taken_num - 6'd16] <= 1'b0;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // pick the highest priority pending and enabled exception
  //
  // svcall is not included: an svc instruction is synchronous, the cpu takes it
  // directly rather than going through the pending logic
  // ---------------------------------------------------------------------------
  reg [5:0] sel_num;
  reg [2:0] sel_prio;
  reg       sel_valid;

  integer k;

  always @(*) begin
    sel_valid = 1'b0;
    sel_num   = 6'd0;
    sel_prio  = 3'd6;

    // systick, exception 15
    if (pend_systick && ({1'b0, prio_systick} + 3'd2) < sel_prio) begin
      sel_valid = 1'b1;
      sel_num   = EXC_SYSTICK;
      sel_prio  = {1'b0, prio_systick} + 3'd2;
    end

    // pendsv, exception 14
    if (pend_pendsv && ({1'b0, prio_pendsv} + 3'd2) < sel_prio) begin
      sel_valid = 1'b1;
      sel_num   = EXC_PENDSV;
      sel_prio  = {1'b0, prio_pendsv} + 3'd2;
    end

    // external interrupts, lowest number wins a priority tie
    for (k = 31; k >= 0; k = k - 1) begin
      if (irq_pending[k] && irq_enable[k] &&
          (({1'b0, prio_irq[k]} + 3'd2) <= sel_prio)) begin
        if ((({1'b0, prio_irq[k]} + 3'd2) < sel_prio) || sel_num >= 6'd16) begin
          sel_valid = 1'b1;
          sel_num   = 6'd16 + k[5:0];
          sel_prio  = {1'b0, prio_irq[k]} + 3'd2;
        end
      end
    end
  end

  // registered rather than combinational.
  //
  // the selection above is a 32 way priority comparison, and feeding it
  // straight out lands it in the cpu's exception decision and from there into
  // the stack frame address in a single cycle. that showed up as the critical
  // path of the whole design: nvic/irq_enable -> core/exc_frame.
  //
  // one cycle of interrupt latency on a core that takes sixteen bus
  // transactions to enter an exception is not measurable
  reg       pend_valid_q;
  reg [5:0] pend_num_q;
  reg [2:0] pend_prio_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend_valid_q <= 1'b0;
      pend_num_q   <= 6'd0;
      pend_prio_q  <= 3'd6;
    end else begin
      pend_valid_q <= sel_valid;
      pend_num_q   <= sel_num;
      pend_prio_q  <= sel_prio;
    end
  end

  assign pend_valid = pend_valid_q;
  assign pend_num   = pend_num_q;
  assign pend_prio  = pend_prio_q;

  // ---------------------------------------------------------------------------
  // reads
  // ---------------------------------------------------------------------------
  always @(*) begin
    case (offset)
      12'h010: rdata = {15'd0, syst_countflag, 13'd0, syst_clksource, syst_tickint, syst_enable};
      12'h014: rdata = {8'd0, syst_reload};
      12'h018: rdata = {8'd0, syst_current};
      12'h01c: rdata = 32'h0000_0000;   // no calibration value
      12'h100,
      12'h180: rdata = irq_enable;
      12'h200,
      12'h280: rdata = irq_pending;
      12'hd04: rdata = {3'd0, pend_pendsv, 1'b0, pend_systick, 5'd0,
                        sel_num, 6'd0, 6'd0};
      12'hd1c: rdata = {prio_svc, 30'd0};
      12'hd20: rdata = {prio_systick, 6'd0, prio_pendsv, 22'd0};
      default: begin
        if (offset[11:5] == 7'b0100000) begin
          case (offset[4:2])
            3'd0: rdata = {prio_irq[3], 6'd0, prio_irq[2], 6'd0, prio_irq[1], 6'd0, prio_irq[0], 6'd0};
            3'd1: rdata = {prio_irq[7], 6'd0, prio_irq[6], 6'd0, prio_irq[5], 6'd0, prio_irq[4], 6'd0};
            3'd2: rdata = {prio_irq[11], 6'd0, prio_irq[10], 6'd0, prio_irq[9], 6'd0, prio_irq[8], 6'd0};
            3'd3: rdata = {prio_irq[15], 6'd0, prio_irq[14], 6'd0, prio_irq[13], 6'd0, prio_irq[12], 6'd0};
            3'd4: rdata = {prio_irq[19], 6'd0, prio_irq[18], 6'd0, prio_irq[17], 6'd0, prio_irq[16], 6'd0};
            3'd5: rdata = {prio_irq[23], 6'd0, prio_irq[22], 6'd0, prio_irq[21], 6'd0, prio_irq[20], 6'd0};
            3'd6: rdata = {prio_irq[27], 6'd0, prio_irq[26], 6'd0, prio_irq[25], 6'd0, prio_irq[24], 6'd0};
            default: rdata = {prio_irq[31], 6'd0, prio_irq[30], 6'd0, prio_irq[29], 6'd0, prio_irq[28], 6'd0};
          endcase
        end else begin
          rdata = 32'd0;
        end
      end
    endcase
  end

endmodule

`default_nettype wire

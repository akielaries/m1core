`default_nettype none

// private peripheral bus: coresight rom table, scs, and dwt/bpu id blocks
//
// this is the block that makes a probe believe it is talking to a cortex-m1.
// every id value here is justified in docs/id-contract.md against the black
// magic probe source, do not change one without re-reading that
//
// ahb-lite slave, zero wait states. the address phase is registered so hrdata
// lands in the data phase, which is what a synchronous slave needs to do

module ppb_regs #(
  parameter [31:0] CPUID_VALUE = 32'h410c_c210
) (
  input  wire        clk,
  input  wire        rst_n,

  input  wire        hsel,
  input  wire [31:0] haddr,
  input  wire        hwrite,
  input  wire [1:0]  htrans,
  input  wire        hready,
  input  wire [31:0] hwdata,
  output reg  [31:0] hrdata,

  // debug control to the core
  output wire        dbg_halt_req,
  output wire        dbg_step_req,
  output wire        dbg_en,
  output wire [31:0] demcr_out,

  // system reset request from AIRCR.SYSRESETREQ, one cycle pulse
  output reg         sys_reset_req,
  // demcr vector catch on core reset
  output wire        vc_corereset,

  // core status
  input  wire        core_halted,
  input  wire        core_halt_event,
  input  wire        core_bkpt,

  // interrupt sources and the cpu's exception interface, both just pass
  // through to the nvic which lives inside this page
  input  wire [31:0] irq_in,
  output wire        pend_valid,
  output wire [5:0]  pend_num,
  output wire [2:0]  pend_prio,
  input  wire        exc_taken,
  input  wire [5:0]  exc_taken_num,

  // core register access, driven by dcrsr/dcrdr
  output reg         dreg_req,
  output reg         dreg_wnr,
  output reg  [4:0]  dreg_sel,
  output reg  [31:0] dreg_wdata,
  input  wire        dreg_ack,
  input  wire [31:0] dreg_rdata
);

  // component bases within the ppb
  localparam [19:0] BASE_DWT = 20'h01000;
  localparam [19:0] BASE_BPU = 20'h02000;
  localparam [19:0] BASE_SCS = 20'h0e000;
  localparam [19:0] BASE_ROM = 20'hff000;

  // scs register offsets from 0xe000e000
  localparam [11:0] SCS_CPUID = 12'hd00;
  localparam [11:0] SCS_AIRCR = 12'hd0c;
  localparam [11:0] SCS_DFSR  = 12'hd30;
  localparam [11:0] SCS_CTR   = 12'hd7c;
  localparam [11:0] SCS_DHCSR = 12'hdf0;
  localparam [11:0] SCS_DCRSR = 12'hdf4;
  localparam [11:0] SCS_DCRDR = 12'hdf8;
  localparam [11:0] SCS_DEMCR = 12'hdfc;

  // address phase capture
  reg [19:0] a_addr;
  reg        a_write;
  reg        a_valid;

  wire addr_phase = hsel && hready && htrans[1];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_addr  <= 20'd0;
      a_write <= 1'b0;
      a_valid <= 1'b0;
    end else begin
      a_valid <= addr_phase;
      if (addr_phase) begin
        a_addr  <= haddr[19:0];
        a_write <= hwrite;
      end
    end
  end

  wire [19:0] comp_base = {a_addr[19:12], 12'd0};
  wire [11:0] off       = a_addr[11:0];

  // offsets inside the scs page that belong to the nvic rather than to debug:
  // systick, the nvic enable/pending/priority banks, icsr and shpr2/3
  wire nvic_range = (off[11:4] == 8'h01)          ||
                    (off[11:8] == 4'h1)           ||
                    (off[11:8] == 4'h2)           ||
                    (off[11:5] == 7'b0100000)     ||
                    (off == 12'hd04)              ||
                    (off == 12'hd1c)              ||
                    (off == 12'hd20);

  wire        nvic_sel = a_valid && (comp_base == BASE_SCS) && nvic_range;
  wire [31:0] nvic_rdata;

  m1core_nvic u_nvic (
    .clk           (clk),
    .rst_n         (rst_n),
    .sel           (nvic_sel),
    .offset        (off),
    .write         (a_write),
    .wdata         (hwdata),
    .rdata         (nvic_rdata),
    .irq_in        (irq_in),
    .pend_valid    (pend_valid),
    .pend_num      (pend_num),
    .pend_prio     (pend_prio),
    .exc_taken     (exc_taken),
    .exc_taken_num (exc_taken_num)
  );

  // debug registers
  reg        c_debugen, c_halt, c_step, c_maskints;
  reg        s_reset_st;
  reg [31:0] demcr;
  reg [31:0] dcrdr;
  reg [31:0] aircr;
  reg [4:0]  dfsr;
  reg        dreg_busy;

  assign dbg_halt_req = c_halt;
  assign dbg_step_req = c_step;
  assign dbg_en       = c_debugen;
  assign demcr_out    = demcr;
  assign vc_corereset = demcr[0];

  // s_halt comes from the core now. cortexm_attach polls this after asking for
  // a halt and gives up if it never sets
  wire [31:0] dhcsr_value = {
    6'd0,
    s_reset_st,   // 25 s_reset_st, sticky, cleared by reading dhcsr
    1'b0,         // 24 s_retire_st
    4'd0,         // 23:20
    1'b0,         // 19 s_lockup
    1'b0,         // 18 s_sleep
    core_halted,  // 17 s_halt
    !dreg_busy,   // 16 s_regrdy
    9'd0,         // 15:7
    1'b0,         // 6
    1'b0,         // 5 c_snapstall
    1'b0,         // 4
    c_maskints,   // 3
    c_step,       // 2
    c_halt,       // 1
    c_debugen     // 0
  };

  // coresight id registers, see docs/id-contract.md
  // part numbers: rom 0x470, scs 0x008, dwt 0x00a, bpu 0x00b
  // designer arm, so pidr1[7:4]=0xb, pidr2=0x0b, pidr4=0x04, size must be 0
  function automatic [31:0] id_regs(input [11:0] offset,
                                    input [11:0] part,
                                    input [3:0]  cls);
    begin
      case (offset)
        12'hfd0: id_regs = 32'h0000_0004;                    // pidr4
        12'hfd4: id_regs = 32'd0;                            // pidr5
        12'hfd8: id_regs = 32'd0;                            // pidr6
        12'hfdc: id_regs = 32'd0;                            // pidr7
        12'hfe0: id_regs = {24'd0, part[7:0]};               // pidr0
        12'hfe4: id_regs = {24'd0, 4'hb, part[11:8]};        // pidr1
        12'hfe8: id_regs = 32'h0000_000b;                    // pidr2, jedec + des
        12'hfec: id_regs = 32'd0;                            // pidr3
        12'hff0: id_regs = 32'h0000_000d;                    // cidr0
        12'hff4: id_regs = {24'd0, cls, 4'd0};               // cidr1, class
        12'hff8: id_regs = 32'h0000_0005;                    // cidr2
        12'hffc: id_regs = 32'h0000_00b1;                    // cidr3
        default: id_regs = 32'd0;
      endcase
    end
  endfunction

  always @(*) begin
    hrdata = 32'd0;
    case (comp_base)
      BASE_ROM: begin
        case (off)
          // entry offsets are signed and relative to the rom table base
          12'h000: hrdata = 32'hfff0_f003;   // scs @ 0xe000e000
          12'h004: hrdata = 32'hfff0_2003;   // dwt @ 0xe0001000
          12'h008: hrdata = 32'hfff0_3003;   // bpu @ 0xe0002000
          12'h00c: hrdata = 32'h0000_0000;   // end of table
          12'hfcc: hrdata = 32'h0000_0001;   // memtype, sysmem present
          default: hrdata = id_regs(off, 12'h470, 4'h1);
        endcase
      end

      BASE_SCS: if (nvic_range) begin
        hrdata = nvic_rdata;
      end else begin
        case (off)
          SCS_CPUID: hrdata = CPUID_VALUE;
          SCS_AIRCR: hrdata = {16'hfa05, aircr[15:0]};
          SCS_DFSR:  hrdata = {27'd0, dfsr};
          SCS_CTR:   hrdata = 32'd0;
          SCS_DHCSR: hrdata = dhcsr_value;
          SCS_DCRDR: hrdata = dcrdr;
          SCS_DEMCR: hrdata = demcr;
          default:   hrdata = id_regs(off, 12'h008, 4'he);
        endcase
      end

      // no watchpoint comparators yet, numcomp in [31:28] reads 0
      BASE_DWT: begin
        case (off)
          12'h000: hrdata = 32'd0;
          default: hrdata = id_regs(off, 12'h00a, 4'he);
        endcase
      end

      // no hardware breakpoint comparators yet, num_code reads 0 so gdb falls
      // back to software breakpoints in ram, which is fine for the mvp
      BASE_BPU: begin
        case (off)
          12'h000: hrdata = 32'd0;
          default: hrdata = id_regs(off, 12'h00b, 4'he);
        endcase
      end

      default: hrdata = 32'd0;
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c_debugen  <= 1'b0;
      c_halt     <= 1'b0;
      c_step     <= 1'b0;
      c_maskints <= 1'b0;
      s_reset_st <= 1'b1;
      demcr      <= 32'd0;
      dcrdr      <= 32'd0;
      aircr      <= 32'd0;
      dfsr       <= 5'b00001;   // halted
      sys_reset_req <= 1'b0;
      dreg_req   <= 1'b0;
      dreg_busy  <= 1'b0;
      dreg_wnr   <= 1'b0;
      dreg_sel   <= 5'd0;
      dreg_wdata <= 32'd0;
    end else begin
      sys_reset_req <= 1'b0;

      // core register access handshake
      if (dreg_ack) begin
        dreg_req  <= 1'b0;
        dreg_busy <= 1'b0;
        if (!dreg_wnr) begin
          // a debug register read lands in dcrdr for the debugger to collect
          dcrdr <= dreg_rdata;
        end
      end

      if (core_bkpt) begin
        dfsr[1] <= 1'b1;
      end

      // hardware sets c_halt when the core stops itself, exactly as a real
      // cortex-m does. placed before the register write block so a debugger
      // write in the same cycle still wins
      if (core_halt_event) begin
        c_halt <= 1'b1;
      end

      if (a_valid) begin
        if (a_write) begin
        if (comp_base == BASE_SCS) begin
          case (off)
            // the dbgkey in the top half must match or the write is ignored
            SCS_DHCSR: begin
              if (hwdata[31:16] == 16'ha05f) begin
                c_debugen  <= hwdata[0];
                c_halt     <= hwdata[1];
                c_step     <= hwdata[2];
                c_maskints <= hwdata[3];
              end
            end
            // hand the access to the core, s_regrdy stays low until it answers.
            // only while halted: the core services these from its halted state,
            // so a request made while running would never be acked and s_regrdy
            // would hang low forever
            SCS_DCRSR: begin
              if (core_halted) begin
                dreg_req   <= 1'b1;
                dreg_busy  <= 1'b1;
                dreg_wnr   <= hwdata[16];
                dreg_sel   <= hwdata[4:0];
                dreg_wdata <= dcrdr;
              end
            end
            SCS_DCRDR: dcrdr <= hwdata;
            SCS_DEMCR: demcr <= hwdata;
            // the vectkey in the top half must match or the write is ignored.
            // sysresetreq is how a debugger resets a core with no nrst wired,
            // which is our case, so this is the only reset path gdb has
            SCS_AIRCR: begin
              if (hwdata[31:16] == 16'h05fa) begin
                aircr <= {16'd0, hwdata[15:0]};
                if (hwdata[2]) begin
                  sys_reset_req <= 1'b1;
                  s_reset_st    <= 1'b1;
                end
              end
            end
            // dfsr bits are write one to clear
            SCS_DFSR:  dfsr <= dfsr & ~hwdata[4:0];
            default: begin
            end
          endcase
        end
      end else begin
        // reading dhcsr clears the sticky reset status bit, otherwise bmp can
        // spin forever waiting for the core to come out of reset
        if (comp_base == BASE_SCS && off == SCS_DHCSR) begin
          s_reset_st <= 1'b0;
        end
        end
      end
    end
  end

endmodule

`default_nettype wire

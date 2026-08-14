`default_nettype none

// mvp top level: a debug access path with memory behind it, and no cpu yet
//
// what this is for: attach a black magic probe, have it discover a cortex-m1
// through the rom table, and let gdb load write firmware into the itcm. once
// that works end to end on hardware, the core gets built behind it

module m1_mvp_top #(
  parameter ITCM_WORDS  = 4096,   // 16 kb
  parameter DTCM_WORDS  = 2048,   // 8 kb
  parameter GPIO_WIDTH  = 2,
  parameter              ITCM_INIT   = ""
) (
  input  wire        clk,
  input  wire        rst_n,

  // swd from the probe
  input  wire        swclk,
  inout  wire        swdio,

  // status indicators, driven by hardware not firmware
  output wire [3:0]  led,

  // firmware controlled pins, also reachable from gdb over swd
  output wire [GPIO_WIDTH-1:0]gpio
);

  // power on reset, so the design comes up correctly whether rst_n is wired to
  // a button or just tied high
  reg [7:0] por_cnt = 8'd0;
  reg       por_n = 1'b0;

  always @(posedge clk) begin
    if (por_cnt != 8'hff) begin
      por_cnt <= por_cnt + 8'd1;
      por_n   <= 1'b0;
    end else begin
      por_n <= 1'b1;
    end
  end

  wire rst_n_i = rst_n && por_n;

  // swd phy
  wire        swdio_o, swdio_oe;
  wire        req_valid, req_apndp, req_rnw;
  wire [1:0]  req_addr;
  wire [2:0]  rsp_ack;
  wire [31:0] rsp_rdata;
  wire        wr_valid, wr_parity_ok;
  wire [31:0] wr_data;
  wire        line_reset;

  assign swdio = swdio_oe ? swdio_o : 1'bz;

  swd_phy u_phy (
    .clk          (clk),
    .rst_n        (rst_n_i),
    .swclk_i      (swclk),
    .swdio_i      (swdio),
    .swdio_o      (swdio_o),
    .swdio_oe     (swdio_oe),
    .req_valid    (req_valid),
    .req_apndp    (req_apndp),
    .req_rnw      (req_rnw),
    .req_addr     (req_addr),
    .rsp_ack      (rsp_ack),
    .rsp_rdata    (rsp_rdata),
    .wr_valid     (wr_valid),
    .wr_parity_ok (wr_parity_ok),
    .wr_data      (wr_data),
    .line_reset   (line_reset)
  );

  // debug port
  wire        ap_req, ap_rnw;
  wire [7:0]  ap_sel;
  wire [5:0]  ap_addr;
  wire [31:0] ap_wdata, ap_rdata;
  wire        ap_ack, ap_fault;
  wire        dbg_pwrup, sys_pwrup, dbg_reset_req;

  sw_dp u_dp (
    .clk           (clk),
    .rst_n         (rst_n_i),
    .req_valid     (req_valid),
    .req_apndp     (req_apndp),
    .req_rnw       (req_rnw),
    .req_addr      (req_addr),
    .rsp_ack       (rsp_ack),
    .rsp_rdata     (rsp_rdata),
    .wr_valid      (wr_valid),
    .wr_parity_ok  (wr_parity_ok),
    .wr_data       (wr_data),
    .line_reset    (line_reset),
    .ap_req        (ap_req),
    .ap_rnw        (ap_rnw),
    .ap_sel        (ap_sel),
    .ap_addr       (ap_addr),
    .ap_wdata      (ap_wdata),
    .ap_ack        (ap_ack),
    .ap_rdata      (ap_rdata),
    .ap_fault      (ap_fault),
    .dbg_pwrup     (dbg_pwrup),
    .sys_pwrup     (sys_pwrup),
    .dbg_reset_req (dbg_reset_req)
  );

  // shared bus, two masters
  wire [31:0] haddr, hwdata;
  wire        hwrite;
  wire [2:0]  hsize, hburst;
  wire [1:0]  htrans;
  wire [3:0]  hprot;
  wire [31:0] hrdata;
  wire        hready, hresp;

  wire        dap_req, dap_write, dap_gnt;
  wire [31:0] dap_addr, dap_wdata;
  wire [2:0]  dap_size;

  wire        cpu_req, cpu_write, cpu_gnt;
  wire [31:0] cpu_addr, cpu_wdata;
  wire [2:0]  cpu_size;

  mem_ap u_ap (
    .clk       (clk),
    .rst_n     (rst_n_i),
    .ap_req    (ap_req),
    .ap_rnw    (ap_rnw),
    .ap_sel    (ap_sel),
    .ap_addr   (ap_addr),
    .ap_wdata  (ap_wdata),
    .ap_ack    (ap_ack),
    .ap_rdata  (ap_rdata),
    .ap_fault  (ap_fault),
    .bus_req   (dap_req),
    .bus_addr  (dap_addr),
    .bus_write (dap_write),
    .bus_size  (dap_size),
    .bus_wdata (dap_wdata),
    .bus_gnt   (dap_gnt),
    .hrdata    (hrdata),
    .hresp     (hresp)
  );

  wire        dbg_halt_req, dbg_step_req, dbg_en;
  wire        sys_reset_req, vc_corereset;
  wire        core_halted, core_bkpt, core_halt_event;
  wire        dreg_req, dreg_wnr, dreg_ack;
  wire [4:0]  dreg_sel;
  wire [31:0] dreg_wdata, dreg_rdata;
  wire [31:0] demcr;

  armv6m_core u_core (
    .clk          (clk),
    .rst_n        (rst_n_i),
    .bus_req      (cpu_req),
    .bus_addr     (cpu_addr),
    .bus_write    (cpu_write),
    .bus_size     (cpu_size),
    .bus_wdata    (cpu_wdata),
    .bus_gnt      (cpu_gnt),
    .bus_rdata    (hrdata),
    .dbg_en        (dbg_en),
    .sys_reset_req (sys_reset_req),
    .vc_corereset  (vc_corereset),
    .dbg_halt_req (dbg_halt_req),
    .dbg_step_req (dbg_step_req),
    .dbg_halted   (core_halted),
    .dbg_halt_event (core_halt_event),
    .dbg_bkpt_hit (core_bkpt),
    .dreg_req     (dreg_req),
    .dreg_wnr     (dreg_wnr),
    .dreg_sel     (dreg_sel),
    .dreg_wdata   (dreg_wdata),
    .dreg_ack     (dreg_ack),
    .dreg_rdata   (dreg_rdata)
  );

  ahb_arb u_arb (
    .clk      (clk),
    .rst_n    (rst_n_i),
    .m0_req   (dap_req),
    .m0_addr  (dap_addr),
    .m0_write (dap_write),
    .m0_size  (dap_size),
    .m0_wdata (dap_wdata),
    .m0_gnt   (dap_gnt),
    .m1_req   (cpu_req),
    .m1_addr  (cpu_addr),
    .m1_write (cpu_write),
    .m1_size  (cpu_size),
    .m1_wdata (cpu_wdata),
    .m1_gnt   (cpu_gnt),
    .haddr    (haddr),
    .hwrite   (hwrite),
    .hsize    (hsize),
    .htrans   (htrans),
    .hburst   (hburst),
    .hprot    (hprot),
    .hwdata   (hwdata),
    .hready   (hready)
  );

  // bus fabric and slaves
  wire        hsel_itcm, hsel_dtcm, hsel_gpio, hsel_ppb;
  wire [31:0] hrdata_itcm, hrdata_dtcm, hrdata_gpio, hrdata_ppb;

  ahb_fabric u_fabric (
    .clk         (clk),
    .rst_n       (rst_n_i),
    .haddr       (haddr),
    .htrans      (htrans),
    .hrdata      (hrdata),
    .hready      (hready),
    .hresp       (hresp),
    .hsel_itcm   (hsel_itcm),
    .hsel_dtcm   (hsel_dtcm),
    .hsel_gpio   (hsel_gpio),
    .hsel_ppb    (hsel_ppb),
    .hrdata_itcm (hrdata_itcm),
    .hrdata_dtcm (hrdata_dtcm),
    .hrdata_gpio (hrdata_gpio),
    .hrdata_ppb  (hrdata_ppb)
  );

  ahb_gpio #(
    .WIDTH (GPIO_WIDTH)
  ) u_gpio (
    .clk    (clk),
    .rst_n  (rst_n_i),
    .hsel   (hsel_gpio),
    .haddr  (haddr),
    .hwrite (hwrite),
    .htrans (htrans),
    .hready (hready),
    .hwdata (hwdata),
    .hrdata (hrdata_gpio),
    .gpio_o (gpio)
  );

  ahb_sram #(
    .WORDS     (ITCM_WORDS),
    .INIT_FILE (ITCM_INIT)
  ) u_itcm (
    .clk    (clk),
    .rst_n  (rst_n_i),
    .hsel   (hsel_itcm),
    .haddr  (haddr),
    .hwrite (hwrite),
    .hsize  (hsize),
    .htrans (htrans),
    .hready (hready),
    .hwdata (hwdata),
    .hrdata (hrdata_itcm)
  );

  ahb_sram #(
    .WORDS (DTCM_WORDS)
  ) u_dtcm (
    .clk    (clk),
    .rst_n  (rst_n_i),
    .hsel   (hsel_dtcm),
    .haddr  (haddr),
    .hwrite (hwrite),
    .hsize  (hsize),
    .htrans (htrans),
    .hready (hready),
    .hwdata (hwdata),
    .hrdata (hrdata_dtcm)
  );

  ppb_regs u_ppb (
    .clk          (clk),
    .rst_n        (rst_n_i),
    .hsel         (hsel_ppb),
    .haddr        (haddr),
    .hwrite       (hwrite),
    .htrans       (htrans),
    .hready       (hready),
    .hwdata       (hwdata),
    .hrdata       (hrdata_ppb),
    .dbg_halt_req (dbg_halt_req),
    .dbg_step_req (dbg_step_req),
    .dbg_en       (dbg_en),
    .demcr_out    (demcr),
    .sys_reset_req (sys_reset_req),
    .vc_corereset  (vc_corereset),
    .core_halted  (core_halted),
    .core_halt_event (core_halt_event),
    .core_bkpt    (core_bkpt),
    .dreg_req     (dreg_req),
    .dreg_wnr     (dreg_wnr),
    .dreg_sel     (dreg_sel),
    .dreg_wdata   (dreg_wdata),
    .dreg_ack     (dreg_ack),
    .dreg_rdata   (dreg_rdata)
  );

  // ---------------------------------------------------------------------------
  // bring-up staircase
  //
  //   led0  heartbeat, the fabric is clocked
  //   led1  swclk edges are arriving at the pin
  //   led2  a line reset was recognised          (sticky)
  //   led3  a well formed packet was decoded     (sticky)
  //
  // each stage can only happen if the previous one did, so a failed scan points
  // straight at a stage rather than leaving every led dark. the two upper ones
  // latch instead of flickering, because "did this ever happen" is the question
  // being asked and a flicker is easy to miss.
  //
  // led1 dark        -> nothing reaching the pin, wiring or pin assignment
  // led1 only        -> clock seen but no line reset recognised, almost always
  //                     swclk too fast for the oversampler, slow the probe
  // led1+led2 only   -> framing or parity, the packet decoder is rejecting it
  // all four         -> the dp is talking, look at the rom table walk instead
  //
  // once scanning works these can go back to reporting dbg_pwrup and dbg_en,
  // which are only meaningful after a successful attach
  // ---------------------------------------------------------------------------
  reg [23:0] hb;
  reg [19:0] act;
  reg [2:0]  swclk_edge_sync;
  reg        saw_line_reset;
  reg        saw_packet;

  always @(posedge clk or negedge rst_n_i) begin
    if (!rst_n_i) begin
      hb              <= 24'd0;
      act             <= 20'd0;
      swclk_edge_sync <= 3'b000;
      saw_line_reset  <= 1'b0;
      saw_packet      <= 1'b0;
    end else begin
      hb <= hb + 24'd1;

      // detect swclk toggling at all, independently of the phy's own framing
      swclk_edge_sync <= {swclk_edge_sync[1:0], swclk};
      if (swclk_edge_sync[2] ^ swclk_edge_sync[1]) begin
        act <= 20'hfffff;
      end else if (act != 20'd0) begin
        act <= act - 20'd1;
      end

      if (line_reset) begin
        saw_line_reset <= 1'b1;
      end
      if (req_valid) begin
        saw_packet <= 1'b1;
      end
    end
  end

  assign led = {saw_packet, saw_line_reset, act != 20'd0, hb[23]};

endmodule

`default_nettype wire

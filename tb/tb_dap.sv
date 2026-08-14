`timescale 1ns/1ps
`default_nettype none

// bit level swd host model driving the phy and dp
//
// sysclk 100 mhz, swclk 5 mhz, so 20x oversampling. the host drives swdio ahead
// of each rising edge and samples on the rising edge, which is what a real probe
// does, so the dut has to get its falling edge drive timing right to pass

module tb_dap;

  localparam time SYSCLK_HALF = 5ns;
  localparam time SWCLK_HALF  = 100ns;

  localparam logic [31:0] DPIDR_EXPECT = 32'h0c10_1477;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #SYSCLK_HALF clk = ~clk;

  // swd wiring, both sides open drain onto a pulled up net
  logic swclk = 1'b0;
  logic host_dio = 1'b0;
  logic host_oe = 1'b0;

  wire  dut_o, dut_oe;
  wire  swdio;

  assign swdio = host_oe ? host_dio : 1'bz;
  assign swdio = dut_oe  ? dut_o    : 1'bz;
  pullup (swdio);

  // phy to dp
  wire        req_valid, req_apndp, req_rnw;
  wire [1:0]  req_addr;
  wire [2:0]  rsp_ack;
  wire [31:0] rsp_rdata;
  wire        wr_valid, wr_parity_ok;
  wire [31:0] wr_data;
  wire        line_reset;

  // dp to ap
  wire        ap_req, ap_rnw;
  wire [7:0]  ap_sel;
  wire [5:0]  ap_addr;
  wire [31:0] ap_wdata;
  logic       ap_ack = 1'b0;
  logic [31:0] ap_rdata = 32'd0;
  logic       ap_fault = 1'b0;

  wire dbg_pwrup, sys_pwrup, dbg_reset_req;

  swd_phy u_phy (
    .clk          (clk),
    .rst_n        (rst_n),
    .swclk_i      (swclk),
    .swdio_i      (swdio),
    .swdio_o      (dut_o),
    .swdio_oe     (dut_oe),
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

  sw_dp #(
    .DPIDR_VALUE (DPIDR_EXPECT)
  ) u_dp (
    .clk           (clk),
    .rst_n         (rst_n),
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

  // stub ap, answers after a few cycles with a value derived from the address
  logic [31:0] ap_mem [0:63];
  integer      ap_delay;

  always @(posedge clk) begin
    ap_ack <= 1'b0;
    if (ap_req) begin
      ap_delay <= 3;
    end else if (ap_delay > 0) begin
      ap_delay <= ap_delay - 1;
      if (ap_delay == 1) begin
        ap_ack <= 1'b1;
        if (!ap_rnw) begin
          ap_mem[ap_addr] <= ap_wdata;
        end else begin
          ap_rdata <= ap_mem[ap_addr];
        end
      end
    end
  end

  integer errors = 0;

  `include "swd_host.svh"

  // optional trace of what the framer actually decoded
  always @(posedge clk) begin
    if ($test$plusargs("dbg")) begin
      if (line_reset) begin
        $display("%t LINE_RESET", $time);
      end
      if (req_valid) begin
        $display("%t REQ apndp=%b rnw=%b a=%b -> ack=%b", $time,
                 req_apndp, req_rnw, req_addr, rsp_ack);
      end
      if (wr_valid) begin
        $display("%t WDATA %08x parity_ok=%b", $time, wr_data, wr_parity_ok);
      end
    end
  end

  // checks
  task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] want);
    begin
      if (got !== want) begin
        $display("FAIL %-28s got %08x want %08x", what, got, want);
        errors = errors + 1;
      end else begin
        $display("ok   %-28s %08x", what, got);
      end
    end
  endtask

  task automatic expect_ack(input string what, input logic [2:0] got, input logic [2:0] want);
    begin
      if (got !== want) begin
        $display("FAIL %-28s ack %03b want %03b", what, got, want);
        errors = errors + 1;
      end else begin
        $display("ok   %-28s ack %03b", what, got);
      end
    end
  endtask

  logic [2:0]  ack;
  logic [31:0] data;
  logic        pok;
  integer      k;

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_dap.vcd");
      $dumpvars(0, tb_dap);
    end

    for (k = 0; k < 64; k = k + 1) begin
      ap_mem[k] = 32'hA5A50000 + k;
    end
    ap_delay = 0;

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (300) @(posedge clk);

    swd_line_reset();

    // 1. dpidr, the very first thing any probe reads
    swd_read(1'b0, 2'b00, ack, data, pok);
    expect_ack("dpidr", ack, 3'b001);
    expect32("dpidr", data, DPIDR_EXPECT);
    if (!pok) begin
      $display("FAIL dpidr read parity");
      errors = errors + 1;
    end

    // 2. ctrl/stat before power up
    swd_read(1'b0, 2'b01, ack, data, pok);
    expect_ack("ctrlstat cold", ack, 3'b001);
    expect32("ctrlstat cold", data, 32'h0000_0000);

    // 3. an ap access before debug power up must fault
    swd_read(1'b1, 2'b00, ack, data, pok);
    expect_ack("ap read unpowered", ack, 3'b100);

    // 4. power up handshake, bmp blocks here until the acks come back
    swd_write(1'b0, 2'b01, 32'h5000_0000, ack);
    expect_ack("ctrlstat powerup write", ack, 3'b001);
    swd_read(1'b0, 2'b01, ack, data, pok);
    expect_ack("ctrlstat powered", ack, 3'b001);
    expect32("ctrlstat powered", data, 32'hf000_0000);

    // 5. select ap bank 0
    swd_write(1'b0, 2'b10, 32'h0000_0000, ack);
    expect_ack("select write", ack, 3'b001);

    // 6. posted ap read. the first returns the stale buffer, the second the
    //    value fetched by the first. this is the semantic that trips people up
    swd_read(1'b1, 2'b00, ack, data, pok);
    expect_ack("ap read 1 posted", ack, 3'b001);
    swd_read(1'b0, 2'b11, ack, data, pok);
    expect_ack("rdbuff", ack, 3'b001);
    expect32("rdbuff has ap[0]", data, 32'hA5A5_0000);

    // 7. ap write then read back through the posted path
    swd_write(1'b1, 2'b01, 32'hdead_beef, ack);
    expect_ack("ap write", ack, 3'b001);
    swd_read(1'b1, 2'b01, ack, data, pok);
    expect_ack("ap read 2", ack, 3'b001);
    swd_read(1'b0, 2'b11, ack, data, pok);
    expect32("rdbuff has written val", data, 32'hdead_beef);

    // 8. a line reset mid stream must not clear the power up bits
    swd_line_reset();
    swd_read(1'b0, 2'b00, ack, data, pok);
    expect_ack("dpidr after reset", ack, 3'b001);
    expect32("dpidr after reset", data, DPIDR_EXPECT);
    // readok (bit 6) is set by the successful ap reads above and a line reset
    // does not clear it, only the power up bits are under test here
    swd_read(1'b0, 2'b01, ack, data, pok);
    expect32("ctrlstat survives reset", data, 32'hf000_0040);

    $display("");
    if (errors == 0) begin
      $display("PASS");
    end else begin
      $display("FAIL, %0d error(s)", errors);
    end
    $finish;
  end

  initial begin
    #2ms;
    $display("FAIL timeout");
    $finish;
  end

endmodule

`default_nettype wire

// bit level swd host model, shared by the testbenches
//
// the including module must declare, before the include:
//   localparam time SWCLK_HALF;
//   logic swclk, host_dio, host_oe;
//   wire  swdio;
//
// the host drives swdio ahead of each rising edge and samples on the rising
// edge, which is what a real probe does, so the dut has to get its falling edge
// drive timing right to pass

// dp register addresses, a = {a3, a2}
localparam logic [1:0] DP_DPIDR    = 2'b00;  // read
localparam logic [1:0] DP_ABORT    = 2'b00;  // write
localparam logic [1:0] DP_CTRLSTAT = 2'b01;
localparam logic [1:0] DP_SELECT   = 2'b10;  // write
localparam logic [1:0] DP_RDBUFF   = 2'b11;  // read

// mem-ap register addresses within a bank
localparam logic [1:0] AP_CSW = 2'b00;
localparam logic [1:0] AP_TAR = 2'b01;
localparam logic [1:0] AP_DRW = 2'b11;

localparam logic [2:0] ACK_OK    = 3'b001;
localparam logic [2:0] ACK_FAULT = 3'b100;

task automatic swd_bit_out(input logic b);
  begin
    host_oe  = 1'b1;
    host_dio = b;
    #SWCLK_HALF;
    swclk = 1'b1;
    #SWCLK_HALF;
    swclk = 1'b0;
  end
endtask

task automatic swd_bit_in(output logic b);
  begin
    host_oe = 1'b0;
    #SWCLK_HALF;
    swclk = 1'b1;
    b = swdio;
    #SWCLK_HALF;
    swclk = 1'b0;
  end
endtask

// one turnaround clock, nobody drives
task automatic swd_trn;
  begin
    host_oe = 1'b0;
    #SWCLK_HALF;
    swclk = 1'b1;
    #SWCLK_HALF;
    swclk = 1'b0;
  end
endtask

task automatic swd_idle(input integer n);
  integer i;
  begin
    for (i = 0; i < n; i = i + 1) begin
      swd_bit_out(1'b0);
    end
  end
endtask

task automatic swd_line_reset;
  integer i;
  begin
    for (i = 0; i < 60; i = i + 1) begin
      swd_bit_out(1'b1);
    end
    swd_idle(4);
  end
endtask

task automatic swd_request(input logic apndp, input logic rnw, input logic [1:0] a);
  logic parity;
  begin
    parity = apndp ^ rnw ^ a[0] ^ a[1];
    swd_bit_out(1'b1);    // start
    swd_bit_out(apndp);
    swd_bit_out(rnw);
    swd_bit_out(a[0]);    // a2
    swd_bit_out(a[1]);    // a3
    swd_bit_out(parity);
    swd_bit_out(1'b0);    // stop
    swd_bit_out(1'b1);    // park
  end
endtask

task automatic swd_read(input logic apndp, input logic [1:0] a,
                        output logic [2:0] ack, output logic [31:0] data,
                        output logic parity_ok);
  integer i;
  logic   b, par;
  begin
    swd_request(apndp, 1'b1, a);
    swd_trn();
    for (i = 0; i < 3; i = i + 1) begin
      swd_bit_in(b);
      ack[i] = b;
    end
    data = 32'd0;
    par  = 1'b0;
    if (ack == ACK_OK) begin
      for (i = 0; i < 32; i = i + 1) begin
        swd_bit_in(b);
        data[i] = b;
      end
      swd_bit_in(par);
    end
    swd_trn();
    parity_ok = (^data) == par;
    swd_idle(2);
  end
endtask

task automatic swd_write(input logic apndp, input logic [1:0] a,
                         input logic [31:0] data, output logic [2:0] ack);
  integer i;
  logic   b;
  begin
    swd_request(apndp, 1'b0, a);
    swd_trn();
    for (i = 0; i < 3; i = i + 1) begin
      swd_bit_in(b);
      ack[i] = b;
    end
    swd_trn();
    if (ack == ACK_OK) begin
      for (i = 0; i < 32; i = i + 1) begin
        swd_bit_out(data[i]);
      end
      swd_bit_out(^data);
    end
    swd_idle(2);
  end
endtask

// retrying wrappers, a real probe retries on wait
task automatic dp_write(input logic [1:0] a, input logic [31:0] data);
  logic [2:0] ack;
  integer     tries;
  begin
    tries = 0;
    ack = 3'b000;
    while (ack != ACK_OK && tries < 8) begin
      swd_write(1'b0, a, data, ack);
      tries = tries + 1;
    end
    if (ack != ACK_OK) begin
      $display("FAIL dp_write a=%b ack=%03b", a, ack);
      errors = errors + 1;
    end
  end
endtask

task automatic dp_read(input logic [1:0] a, output logic [31:0] data);
  logic [2:0] ack;
  logic       pok;
  integer     tries;
  begin
    tries = 0;
    ack = 3'b000;
    while (ack != ACK_OK && tries < 8) begin
      swd_read(1'b0, a, ack, data, pok);
      tries = tries + 1;
    end
    if (ack != ACK_OK) begin
      $display("FAIL dp_read a=%b ack=%03b", a, ack);
      errors = errors + 1;
    end
  end
endtask

task automatic ap_write(input logic [1:0] a, input logic [31:0] data);
  logic [2:0] ack;
  integer     tries;
  begin
    tries = 0;
    ack = 3'b000;
    while (ack != ACK_OK && tries < 16) begin
      swd_write(1'b1, a, data, ack);
      tries = tries + 1;
    end
    if (ack != ACK_OK) begin
      $display("FAIL ap_write a=%b ack=%03b", a, ack);
      errors = errors + 1;
    end
  end
endtask

// ap reads are posted, so the value comes back from rdbuff afterwards
task automatic ap_read(input logic [1:0] a, output logic [31:0] data);
  logic [2:0] ack;
  logic       pok;
  logic [31:0] dummy;
  integer     tries;
  begin
    tries = 0;
    ack = 3'b000;
    while (ack != ACK_OK && tries < 16) begin
      swd_read(1'b1, a, ack, dummy, pok);
      tries = tries + 1;
    end
    if (ack != ACK_OK) begin
      $display("FAIL ap_read a=%b ack=%03b", a, ack);
      errors = errors + 1;
    end
    dp_read(DP_RDBUFF, data);
  end
endtask

task automatic ap_bank(input logic [3:0] bank);
  begin
    dp_write(DP_SELECT, {24'd0, bank, 4'd0});
  end
endtask

// bring the dap up the way a probe does: reset, read dpidr, power up
task automatic dap_init(output logic [31:0] dpidr);
  logic [31:0] stat;
  integer      tries;
  begin
    swd_line_reset();
    dp_read(DP_DPIDR, dpidr);
    dp_write(DP_ABORT, 32'h0000_001e);
    dp_write(DP_CTRLSTAT, 32'h5000_0000);
    tries = 0;
    stat = 32'd0;
    while ((stat & 32'hA000_0000) != 32'hA000_0000 && tries < 16) begin
      dp_read(DP_CTRLSTAT, stat);
      tries = tries + 1;
    end
    if ((stat & 32'hA000_0000) != 32'hA000_0000) begin
      $display("FAIL power up handshake, ctrlstat=%08x", stat);
      errors = errors + 1;
    end
    ap_bank(4'd0);
  end
endtask

// 32 bit memory access through the mem-ap
task automatic mem32_write(input logic [31:0] addr, input logic [31:0] data);
  begin
    ap_write(AP_TAR, addr);
    ap_write(AP_DRW, data);
  end
endtask

task automatic mem32_read(input logic [31:0] addr, output logic [31:0] data);
  begin
    ap_write(AP_TAR, addr);
    ap_read(AP_DRW, data);
  end
endtask

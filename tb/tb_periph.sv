`timescale 1ns/1ps
`default_nettype none

// unit tests for the apb peripherals
//
// these drive the peripherals on their own apb ports rather than through the
// whole mcu. going through the cpu or the debug port would make every register
// access hundreds of cycles and would test the fabric again rather than the
// block, and a shifting error inside spi is far easier to read here.
//
// the address decode that puts each block in the memory map is covered by
// tb_mvp and tb_exp; what is covered here is what the blocks do

module tb_periph;

  localparam time CLK_HALF = 5ns;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #CLK_HALF clk = ~clk;

  integer errors = 0;

  task automatic expect32(input string what, input logic [31:0] got,
                          input logic [31:0] want);
    begin
      if (got !== want) begin
        $display("FAIL %-34s got %08x want %08x", what, got, want);
        errors = errors + 1;
      end else begin
        $display("ok   %-34s %08x", what, got);
      end
    end
  endtask

  // --- shared apb bus, one select per peripheral ----------------------------
  logic        penable = 1'b0;
  logic        pwrite = 1'b0;
  logic [31:0] paddr = 32'd0;
  logic [31:0] pwdata = 32'd0;
  logic        psel_rtc = 1'b0, psel_spi = 1'b0, psel_i2c = 1'b0;
  wire  [31:0] prdata_rtc, prdata_spi, prdata_i2c;

  localparam int TGT_RTC = 0;
  localparam int TGT_SPI = 1;
  localparam int TGT_I2C = 2;

  task automatic apb_sel(input int tgt, input logic v);
    begin
      psel_rtc = (tgt == TGT_RTC) && v;
      psel_spi = (tgt == TGT_SPI) && v;
      psel_i2c = (tgt == TGT_I2C) && v;
    end
  endtask

  task automatic apb_wr(input int tgt, input logic [31:0] a,
                        input logic [31:0] d);
    begin
      // driven on the negedge so every signal is stable across the posedge the
      // peripheral samples on. driving on the posedge is a race, and it showed
      // up as write-one-to-clear appearing not to work
      @(negedge clk);
      paddr = a; pwdata = d; pwrite = 1'b1; apb_sel(tgt, 1'b1); penable = 1'b0;
      @(negedge clk);
      penable = 1'b1;
      @(negedge clk);
      penable = 1'b0; pwrite = 1'b0; apb_sel(tgt, 1'b0);
    end
  endtask

  task automatic apb_rd(input int tgt, input logic [31:0] a,
                        output logic [31:0] d);
    begin
      @(negedge clk);
      paddr = a; pwrite = 1'b0; apb_sel(tgt, 1'b1); penable = 1'b0;
      @(negedge clk);
      penable = 1'b1;
      case (tgt)
        TGT_RTC: d = prdata_rtc;
        TGT_SPI: d = prdata_spi;
        default: d = prdata_i2c;
      endcase
      @(negedge clk);
      penable = 1'b0; apb_sel(tgt, 1'b0);
    end
  endtask

  // --- rtc ------------------------------------------------------------------
  wire rtc_irq;
  apb_rtc u_rtc (
    .clk (clk), .rst_n (rst_n),
    .psel (psel_rtc), .penable (penable), .pwrite (pwrite),
    .paddr (paddr), .pwdata (pwdata), .prdata (prdata_rtc), .pready (),
    .irq (rtc_irq)
  );

  // --- spi, wired as a loopback --------------------------------------------
  //
  // miso tied to mosi means whatever is shifted out comes straight back, so a
  // received byte equal to the transmitted one proves both directions shift at
  // the right edges. that holds for all four modes, which is what makes it a
  // usable check of cpol and cpha rather than just of mode 0
  wire spi_irq, spi_sclk, spi_mosi;
  wire [0:0] spi_ssel_n;
  apb_spi #(.SSEL_WIDTH (1)) u_spi (
    .clk (clk), .rst_n (rst_n),
    .psel (psel_spi), .penable (penable), .pwrite (pwrite),
    .paddr (paddr), .pwdata (pwdata), .prdata (prdata_spi), .pready (),
    .irq (spi_irq),
    .sclk (spi_sclk), .mosi (spi_mosi), .miso (spi_mosi), .ssel_n (spi_ssel_n)
  );

  // --- i2c, with a slave model on the bus -----------------------------------
  wire i2c_irq;
  wire scl, sda;
  pullup (scl);
  pullup (sda);

  apb_i2c u_i2c (
    .clk (clk), .rst_n (rst_n),
    .psel (psel_i2c), .penable (penable), .pwrite (pwrite),
    .paddr (paddr), .pwdata (pwdata), .prdata (prdata_i2c), .pready (),
    .irq (i2c_irq),
    .scl (scl), .sda (sda)
  );

  // a minimal slave at 0x50: acks its own address, stores one byte, and
  // returns a fixed byte on a read
  localparam logic [6:0] SLAVE_ADDR = 7'h50;
  localparam logic [7:0] SLAVE_TX   = 8'hc3;

  logic       sl_drive = 1'b0;
  logic       sl_bit = 1'b0;
  assign sda = (sl_drive && !sl_bit) ? 1'b0 : 1'bz;

  logic [7:0] sl_shift;
  logic [3:0] sl_cnt;
  logic       sl_active = 1'b0;
  logic       sl_addressed = 1'b0;
  logic       sl_reading = 1'b0;
  logic [7:0] sl_rx;
  logic [7:0] sl_txsr;
  integer     sl_byte;

  // start and stop are sda moving while scl is high
  always @(negedge sda) begin
    if (scl === 1'b1) begin
      sl_active = 1'b1;
      sl_cnt = 0;
      sl_byte = 0;
      sl_addressed = 1'b0;
      sl_reading = 1'b0;
      sl_drive = 1'b0;
    end
  end

  always @(posedge sda) begin
    if (scl === 1'b1) begin
      sl_active = 1'b0;
      sl_drive = 1'b0;
    end
  end

  always @(posedge scl) begin
    if (sl_active) begin
      if (sl_cnt < 8) begin
        sl_shift = {sl_shift[6:0], (sda === 1'b0) ? 1'b0 : 1'b1};
      end
      sl_cnt = sl_cnt + 1;
    end
  end

  always @(negedge scl) begin
    if (sl_active) begin
      if (sl_cnt == 8) begin
        // ack phase. the address byte decides whether this slave answers
        if (sl_byte == 0) begin
          sl_addressed = (sl_shift[7:1] == SLAVE_ADDR);
          sl_reading   = sl_shift[0];
          sl_txsr      = SLAVE_TX;
        end else if (!sl_reading) begin
          sl_rx = sl_shift;
        end
        if (sl_addressed && !sl_reading) begin
          sl_drive = 1'b1;
          sl_bit   = 1'b0;      // ack
        end else if (sl_addressed && sl_reading && sl_byte == 0) begin
          sl_drive = 1'b1;
          sl_bit   = 1'b0;
        end else begin
          sl_drive = 1'b0;
        end
      end else if (sl_cnt == 9) begin
        sl_cnt  = 0;
        sl_byte = sl_byte + 1;
        if (sl_addressed && sl_reading) begin
          // start clocking the data byte out, msb first
          sl_drive = 1'b1;
          sl_bit   = sl_txsr[7];
          sl_txsr  = {sl_txsr[6:0], 1'b0};
        end else begin
          sl_drive = 1'b0;
        end
      end else if (sl_addressed && sl_reading && sl_byte > 0) begin
        sl_drive = 1'b1;
        sl_bit   = sl_txsr[7];
        sl_txsr  = {sl_txsr[6:0], 1'b0};
      end
    end
  end

  // --- register offsets -----------------------------------------------------
  localparam logic [31:0] RTC_CTRL = 32'h00, RTC_COUNT = 32'h04,
                          RTC_MATCH = 32'h08, RTC_INT = 32'h0c,
                          RTC_PRESCALE = 32'h10;
  localparam logic [31:0] SPI_CTRL = 32'h00, SPI_STATUS = 32'h04,
                          SPI_DATA = 32'h08, SPI_CLKDIV = 32'h0c,
                          SPI_SSEL = 32'h10, SPI_INT = 32'h14;
  localparam logic [31:0] I2C_CTRL = 32'h00, I2C_CMD = 32'h04,
                          I2C_DATA = 32'h08, I2C_STATUS = 32'h0c,
                          I2C_CLKDIV = 32'h10, I2C_INT = 32'h14;

  logic [31:0] d;
  integer      i;
  integer      mode;

  task automatic spi_xfer(input logic [7:0] byte_out, output logic [31:0] got);
    begin
      apb_wr(TGT_SPI, SPI_DATA, {24'd0, byte_out});
      for (i = 0; i < 4000; i = i + 1) begin
        apb_rd(TGT_SPI, SPI_STATUS, d);
        if (d[0] == 1'b0) begin
          i = 4000;
        end
      end
      apb_rd(TGT_SPI, SPI_DATA, got);
    end
  endtask

  task automatic i2c_wait(input string what);
    begin
      for (i = 0; i < 20000; i = i + 1) begin
        apb_rd(TGT_I2C, I2C_STATUS, d);
        if (d[0] == 1'b0) begin
          i = 20000;
        end
      end
      if (d[0] !== 1'b0) begin
        $display("FAIL %-34s still busy", what);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/tb_periph.vcd");
      $dumpvars(0, tb_periph);
    end

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ======================= rtc =========================================
    $display("-- rtc");
    apb_wr(TGT_RTC, RTC_PRESCALE, 32'd3);   // a tick every four pclk
    apb_wr(TGT_RTC, RTC_MATCH,    32'd5);
    apb_wr(TGT_RTC, RTC_COUNT,    32'd0);
    apb_wr(TGT_RTC, RTC_CTRL,     32'd3);   // EN | IRQEN

    repeat (40) @(posedge clk);
    apb_rd(TGT_RTC, RTC_COUNT, d);
    if (d < 32'd5) begin
      $display("FAIL rtc did not count, got %0d", d);
      errors = errors + 1;
    end else begin
      $display("ok   rtc counted to %0d", d);
    end
    expect32("rtc match raised irq", {31'd0, rtc_irq}, 32'd1);
    apb_rd(TGT_RTC, RTC_INT, d);
    expect32("rtc intstatus pending", d, 32'd1);
    apb_wr(TGT_RTC, RTC_INT, 32'd1);
    expect32("rtc irq cleared", {31'd0, rtc_irq}, 32'd0);

    // a stopped rtc must not advance
    apb_wr(TGT_RTC, RTC_CTRL, 32'd0);
    apb_rd(TGT_RTC, RTC_COUNT, d);
    i = d;
    repeat (40) @(posedge clk);
    apb_rd(TGT_RTC, RTC_COUNT, d);
    expect32("rtc stopped holds", d, i);

    // ======================= spi =========================================
    $display("-- spi");
    apb_wr(TGT_SPI, SPI_CLKDIV, 32'd1);

    for (mode = 0; mode < 4; mode = mode + 1) begin
      // ctrl bit1 is cpol, bit2 is cpha
      apb_wr(TGT_SPI, SPI_CTRL, 32'h1 | (mode << 1));
      repeat (4) @(posedge clk);
      expect32($sformatf("spi mode %0d sclk idles at cpol", mode),
               {31'd0, spi_sclk}, {31'd0, mode[0]});
      spi_xfer(8'ha5, d);
      expect32($sformatf("spi mode %0d loopback a5", mode), d, 32'h0000_00a5);
      spi_xfer(8'h3c, d);
      expect32($sformatf("spi mode %0d loopback 3c", mode), d, 32'h0000_003c);
    end

    apb_wr(TGT_SPI, SPI_CTRL, 32'h9);   // EN | IRQEN
    spi_xfer(8'h5a, d);
    expect32("spi irq after transfer", {31'd0, spi_irq}, 32'd1);
    apb_wr(TGT_SPI, SPI_INT, 32'd1);
    expect32("spi irq cleared", {31'd0, spi_irq}, 32'd0);

    // chip selects are driven straight from the register, active low
    apb_wr(TGT_SPI, SPI_CTRL, 32'h1);
    apb_wr(TGT_SPI, SPI_SSEL, 32'd1);
    repeat (2) @(posedge clk);
    expect32("ssel asserted low", {31'd0, spi_ssel_n[0]}, 32'd0);
    apb_wr(TGT_SPI, SPI_SSEL, 32'd0);
    repeat (2) @(posedge clk);
    expect32("ssel released high", {31'd0, spi_ssel_n[0]}, 32'd1);

    // a transfer must not start while the block is disabled
    apb_wr(TGT_SPI, SPI_CTRL, 32'd0);
    apb_wr(TGT_SPI, SPI_DATA, 32'hff);
    repeat (4) @(posedge clk);
    apb_rd(TGT_SPI, SPI_STATUS, d);
    expect32("disabled spi stays idle", d, 32'd0);

    // ======================= i2c =========================================
    $display("-- i2c");
    apb_wr(TGT_I2C, I2C_CLKDIV, 32'd3);
    apb_wr(TGT_I2C, I2C_CTRL,   32'd1);

    // start, address 0x50 for write, expect the slave to ack
    apb_wr(TGT_I2C, I2C_DATA, {24'd0, SLAVE_ADDR, 1'b0});
    apb_wr(TGT_I2C, I2C_CMD,  32'h5);          // START | WRITE
    i2c_wait("i2c address write");
    apb_rd(TGT_I2C, I2C_STATUS, d);
    expect32("slave acked its address", {31'd0, d[1]}, 32'd0);

    // one data byte, then stop
    apb_wr(TGT_I2C, I2C_DATA, 32'h5a);
    apb_wr(TGT_I2C, I2C_CMD,  32'h6);          // WRITE | STOP
    i2c_wait("i2c data write");
    expect32("slave received the byte", {24'd0, sl_rx}, 32'h0000_005a);

    // an address nobody answers must report a nack
    apb_wr(TGT_I2C, I2C_DATA, {24'd0, 7'h11, 1'b0});
    apb_wr(TGT_I2C, I2C_CMD,  32'h5);
    i2c_wait("i2c unaddressed write");
    apb_rd(TGT_I2C, I2C_STATUS, d);
    expect32("absent slave nacks", {31'd0, d[1]}, 32'd1);
    apb_wr(TGT_I2C, I2C_CMD, 32'h2);           // STOP
    i2c_wait("i2c stop");

    // read a byte back from the slave
    apb_wr(TGT_I2C, I2C_DATA, {24'd0, SLAVE_ADDR, 1'b1});
    apb_wr(TGT_I2C, I2C_CMD,  32'h5);          // START | WRITE
    i2c_wait("i2c address read");
    apb_rd(TGT_I2C, I2C_STATUS, d);
    expect32("slave acked read address", {31'd0, d[1]}, 32'd0);

    apb_wr(TGT_I2C, I2C_CMD, 32'hA);           // READ | STOP, nack the byte
    i2c_wait("i2c data read");
    apb_rd(TGT_I2C, I2C_DATA, d);
    expect32("byte read from slave", d, {24'd0, SLAVE_TX});

    if (errors == 0) begin
      $display("PASS");
    end else begin
      $display("FAIL %0d errors", errors);
    end
    $finish;
  end

endmodule

`default_nettype wire

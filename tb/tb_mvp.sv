`timescale 1ns/1ps
`default_nettype none

// end to end mvp test
//
// this walks the discovery path from pub/blackmagic/src/target/adi.c in the same
// order the probe does, then does what gdb load does. if this passes, the only
// things between here and a real probe attaching are pin constraints and timing

module tb_mvp;

  localparam time SYSCLK_HALF = 5ns;
  localparam time SWCLK_HALF  = 100ns;

  localparam logic [31:0] DPIDR_EXPECT = 32'h0c10_1477;
  localparam logic [31:0] ROM_BASE     = 32'he00f_f000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #SYSCLK_HALF clk = ~clk;

  logic swclk = 1'b0;
  logic host_dio = 1'b0;
  logic host_oe = 1'b0;
  wire  swdio;

  assign swdio = host_oe ? host_dio : 1'bz;
  pullup (swdio);

  integer errors = 0;

  wire [1:0] gpio_pins;

  // itcm is preloaded so the core is genuinely running while the debugger does
  // its discovery walk, which exercises the bus arbiter for free
  m1core_soc #(
    .ITCM_WORDS (4096),
    .DTCM_WORDS (2048),
    .GPIO_WIDTH (2),
    .ITCM_INIT  ("../sw/apps/blink/build-sim/blink_sim.hex")
  ) dut (
    .clk   (clk),
    .rst_n (rst_n),
    .swclk (swclk),
    .swdio (swdio),
    .led   (),
    .gpio  (gpio_pins),
    .uart0_rxd (1'b1),
    .uart0_txd (),
    .uart0_irq ()
  );

  `include "swd_host.svh"

  task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] want);
    begin
      if (got !== want) begin
        $display("FAIL %-30s got %08x want %08x", what, got, want);
        errors = errors + 1;
      end else begin
        $display("ok   %-30s %08x", what, got);
      end
    end
  endtask

  // bmp packs the low byte of four consecutive words into the component id
  task automatic read_cidr(input logic [31:0] base, output logic [31:0] cidr);
    logic [31:0] w0, w1, w2, w3;
    begin
      mem32_read(base + 32'hff0, w0);
      mem32_read(base + 32'hff4, w1);
      mem32_read(base + 32'hff8, w2);
      mem32_read(base + 32'hffc, w3);
      cidr = {w3[7:0], w2[7:0], w1[7:0], w0[7:0]};
    end
  endtask

  task automatic read_pidr(input logic [31:0] base, output logic [63:0] pidr);
    logic [31:0] p0, p1, p2, p3, p4, p5, p6, p7;
    begin
      mem32_read(base + 32'hfe0, p0);
      mem32_read(base + 32'hfe4, p1);
      mem32_read(base + 32'hfe8, p2);
      mem32_read(base + 32'hfec, p3);
      mem32_read(base + 32'hfd0, p4);
      mem32_read(base + 32'hfd4, p5);
      mem32_read(base + 32'hfd8, p6);
      mem32_read(base + 32'hfdc, p7);
      pidr = {p7[7:0], p6[7:0], p5[7:0], p4[7:0],
              p3[7:0], p2[7:0], p1[7:0], p0[7:0]};
    end
  endtask

  // designer code the way adi.c:271-278 reconstructs it
  function automatic [11:0] designer_of(input logic [63:0] pidr);
    begin
      designer_of = {pidr[35:32], 1'b0, pidr[18:12]};
    end
  endfunction

  logic [31:0] dpidr, data, cidr, scs_base, entry;
  logic [63:0] pidr;
  integer      i;

  // firmware image, built by make -C ../fw. the length is discovered rather
  // than hardcoded so the test cannot silently under-verify a bigger image.
  // $readmemh warns that the file is shorter than the array, that is expected
  localparam string FW_HEX = "../sw/apps/blink/build/blink.hex";
  logic [31:0] fw_image [0:1023];
  integer      fw_words;

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_mvp.vcd");
      $dumpvars(0, tb_mvp);
    end

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (300) @(posedge clk);

    // --- what a probe does on connect ---
    dap_init(dpidr);
    expect32("dpidr", dpidr, DPIDR_EXPECT);

    // ap identification lives in bank 0xf
    ap_bank(4'hf);
    ap_read(2'b11, data);
    expect32("ap idr", data, 32'h2477_0011);
    ap_read(2'b10, data);
    expect32("ap base", data, 32'he00f_f003);

    // only apsel 0 exists. a probe walks apsel 0..255 and decides an ap is
    // absent when its IDR reads 0, so every other apsel must answer with zeroes.
    // without this one ap answers everywhere and the probe enumerates 256
    // identical targets, which is exactly what happened on hardware
    dp_write(DP_SELECT, 32'h0100_00f0);            // apsel 1, bank 0xf
    ap_read(2'b11, data);
    expect32("ap idr at apsel 1", data, 32'h0000_0000);
    dp_write(DP_SELECT, 32'hff00_00f0);            // apsel 255
    ap_read(2'b11, data);
    expect32("ap idr at apsel 255", data, 32'h0000_0000);
    dp_write(DP_SELECT, 32'h0000_00f0);            // back to apsel 0
    ap_read(2'b11, data);
    expect32("ap idr at apsel 0", data, 32'h2477_0011);

    // back to bank 0 and set up 32 bit accesses with no auto increment
    ap_bank(4'h0);
    ap_write(AP_CSW, 32'h8000_0002);
    ap_read(AP_CSW, data);
    expect32("csw readback", data, 32'h8000_0042);

    // --- rom table ---
    read_cidr(ROM_BASE, cidr);
    expect32("rom cidr", cidr, 32'hb105_100d);

    read_pidr(ROM_BASE, pidr);
    expect32("rom pidr part", {20'd0, pidr[11:0]}, 32'h0000_0470);
    expect32("rom pidr designer", {20'd0, designer_of(pidr)}, 32'h0000_043b);
    expect32("rom pidr size zero", {28'd0, pidr[39:36]}, 32'h0000_0000);

    mem32_read(ROM_BASE + 32'hfcc, data);
    expect32("rom memtype sysmem", data, 32'h0000_0001);

    // entry 0 points at the scs, offset is signed and relative to the table
    mem32_read(ROM_BASE, entry);
    expect32("rom entry 0", entry, 32'hfff0_f003);
    scs_base = ROM_BASE + (entry & 32'hffff_f000);
    expect32("scs base resolved", scs_base, 32'he000_e000);

    mem32_read(ROM_BASE + 32'h00c, data);
    expect32("rom table terminator", data, 32'h0000_0000);

    // --- scs component ---
    read_cidr(scs_base, cidr);
    expect32("scs cidr", cidr, 32'hb105_e00d);

    read_pidr(scs_base, pidr);
    expect32("scs pidr part", {20'd0, pidr[11:0]}, 32'h0000_0008);
    expect32("scs pidr designer", {20'd0, designer_of(pidr)}, 32'h0000_043b);

    // this is the value that makes bmp print Cortex-M1
    mem32_read(scs_base + 32'hd00, data);
    expect32("cpuid", data, 32'h410c_c210);
    expect32("cpuid partno masked", data & 32'h0000_fff0, 32'h0000_c210);

    // --- the core is running blink right now, so check that first ---
    mem32_read(scs_base + 32'hdf0, data);
    if (data[17]) begin
      $display("FAIL core reports halted before being asked: %08x", data);
      errors = errors + 1;
    end else begin
      $display("ok   core running before attach   %08x", data);
    end

    // --- halt handshake, cortexm_attach fails if s_halt never comes back ---
    mem32_write(scs_base + 32'hdf0, 32'ha05f_0003);   // dbgkey|c_debugen|c_halt
    mem32_read(scs_base + 32'hdf0, data);
    if (!data[17]) begin
      $display("FAIL dhcsr s_halt not set: %08x", data);
      errors = errors + 1;
    end else begin
      $display("ok   dhcsr s_halt                %08x", data);
    end
    expect32("dhcsr control echo", data & 32'h0000_000f, 32'h0000_0003);

    // s_reset_st must clear on read or bmp can spin waiting for reset release
    mem32_read(scs_base + 32'hdf0, data);
    expect32("dhcsr s_reset_st cleared", data & 32'h0200_0000, 32'h0000_0000);

    // --- core register file through dcrsr/dcrdr, what gdb reads ---
    // the pc it stopped at must be inside the firmware image
    mem32_write(scs_base + 32'hdf4, 32'h0000_000f);   // read pc
    mem32_read(scs_base + 32'hdf8, data);
    if (data >= 32'h0000_1000) begin
      $display("FAIL halted pc outside itcm: %08x", data);
      errors = errors + 1;
    end else begin
      $display("ok   halted pc inside firmware   %08x", data);
    end

    mem32_write(scs_base + 32'hdf8, 32'h1234_5678);   // dcrdr
    mem32_write(scs_base + 32'hdf4, 32'h0001_000f);   // write pc
    mem32_write(scs_base + 32'hdf8, 32'h0000_0000);
    mem32_write(scs_base + 32'hdf4, 32'h0000_000f);   // read pc back
    mem32_read(scs_base + 32'hdf8, data);
    expect32("core reg pc via dcrsr", data, 32'h1234_5678);

    // --- what gdb load does ---
    mem32_write(32'h0000_0000, 32'h2000_1000);        // initial sp
    mem32_write(32'h0000_0004, 32'h0000_0101);        // reset vector
    mem32_read(32'h0000_0000, data);
    expect32("itcm word 0", data, 32'h2000_1000);
    mem32_read(32'h0000_0004, data);
    expect32("itcm word 1", data, 32'h0000_0101);

    mem32_write(32'h2000_0010, 32'hcafe_babe);
    mem32_read(32'h2000_0010, data);
    expect32("dtcm word", data, 32'hcafe_babe);

    // an unmapped read must return zero, not a fault, or stickyerr would lock
    // out every later transfer
    mem32_read(32'h6000_0000, data);
    expect32("unmapped reads zero", data, 32'h0000_0000);
    dp_read(DP_CTRLSTAT, data);
    expect32("no sticky error", data & 32'h0000_00a0, 32'h0000_0000);

    // --- auto increment, this is how a real load actually streams ---
    ap_write(AP_CSW, 32'h8000_0012);                  // addrinc single, word
    ap_write(AP_TAR, 32'h0000_0100);
    for (i = 0; i < 8; i = i + 1) begin
      ap_write(AP_DRW, 32'h1000_0000 + i);
    end
    ap_read(AP_TAR, data);
    expect32("tar auto incremented", data, 32'h0000_0120);

    ap_write(AP_CSW, 32'h8000_0002);                  // back to no increment
    for (i = 0; i < 8; i = i + 1) begin
      mem32_read(32'h0000_0100 + (i * 4), data);
      expect32($sformatf("streamed word %0d", i), data, 32'h1000_0000 + i);
    end

    // --- sub word writes, gdb uses these for unaligned tails ---
    ap_write(AP_CSW, 32'h8000_0002);
    mem32_write(32'h0000_0200, 32'hffff_ffff);
    ap_write(AP_CSW, 32'h8000_0000);                  // byte
    ap_write(AP_TAR, 32'h0000_0201);
    ap_write(AP_DRW, 32'h0000_5a00);                  // lane 1
    ap_write(AP_CSW, 32'h8000_0002);
    mem32_read(32'h0000_0200, data);
    expect32("byte write lane 1", data, 32'hffff_5aff);

    ap_write(AP_CSW, 32'h8000_0001);                  // halfword
    ap_write(AP_TAR, 32'h0000_0202);
    ap_write(AP_DRW, 32'h1234_0000);                  // upper half
    ap_write(AP_CSW, 32'h8000_0002);
    mem32_read(32'h0000_0200, data);
    expect32("halfword write upper", data, 32'h1234_5aff);

    // --- gpio, this is what makes a pin move with no cpu in the design ---
    mem32_write(32'h4000_0004, 32'h0000_0003);        // dir, both pins output
    mem32_write(32'h4000_0000, 32'h0000_0003);        // data
    mem32_read(32'h4000_0000, data);
    expect32("gpio data readback", data, 32'h0000_0003);
    expect32("gpio pins driven", {30'd0, gpio_pins}, 32'h0000_0003);

    mem32_write(32'h4000_000c, 32'h0000_0001);        // clr bit 0
    expect32("gpio clr bit 0", {30'd0, gpio_pins}, 32'h0000_0002);

    mem32_write(32'h4000_0008, 32'h0000_0001);        // set bit 0
    expect32("gpio set bit 0", {30'd0, gpio_pins}, 32'h0000_0003);

    // --- load the real firmware image the way gdb load does ---
    $readmemh(FW_HEX, fw_image);
    if (fw_image[0] === 32'hxxxxxxxx) begin
      $display("skip firmware load, %s missing, run make -C ../fw", FW_HEX);
    end else begin
      fw_words = 0;
      while (fw_words < 1024 && fw_image[fw_words] !== 32'hxxxxxxxx) begin
        fw_words = fw_words + 1;
      end

      ap_write(AP_CSW, 32'h8000_0012);                // addrinc single, word
      ap_write(AP_TAR, 32'h0000_0000);
      for (i = 0; i < fw_words; i = i + 1) begin
        ap_write(AP_DRW, fw_image[i]);
      end
      ap_write(AP_CSW, 32'h8000_0002);

      // the two words the core will consume on reset
      mem32_read(32'h0000_0000, data);
      expect32("fw initial sp", data, 32'h2000_2000);
      mem32_read(32'h0000_0004, data);
      if (!data[0]) begin
        $display("FAIL reset vector thumb bit clear: %08x", data);
        errors = errors + 1;
      end else begin
        $display("ok   fw reset vector thumb bit  %08x", data);
      end

      // and the whole image verifies, which is what gdb compare-sections does
      for (i = 0; i < fw_words; i = i + 1) begin
        mem32_read(i * 4, data);
        if (data !== fw_image[i]) begin
          $display("FAIL fw word %0d got %08x want %08x", i, data, fw_image[i]);
          errors = errors + 1;
        end
      end
      $display("ok   fw image verified          %0d words", fw_words);

      // --- sysresetreq, the only reset path gdb has with no nrst wired ---
      // clear c_halt so the halt below can only come from the vector catch
      mem32_write(scs_base + 32'hdf0, 32'ha05f_0001);  // dbgkey|c_debugen
      mem32_write(scs_base + 32'hdfc, 32'h0000_0001);  // demcr vc_corereset
      mem32_write(scs_base + 32'hd0c, 32'h05fa_0004);  // aircr sysresetreq

      // s_reset_st latches the reset and clears on read, which is how bmp
      // confirms the reset happened and then waits for it to be released
      mem32_read(scs_base + 32'hdf0, data);
      if (!data[25]) begin
        $display("FAIL s_reset_st not set after sysresetreq: %08x", data);
        errors = errors + 1;
      end else begin
        $display("ok   s_reset_st set by reset    %08x", data);
      end
      mem32_read(scs_base + 32'hdf0, data);
      expect32("s_reset_st clears on read", data & 32'h0200_0000, 32'h0000_0000);

      // the vector catch must have stopped it, and at the reset handler of the
      // image just loaded, not wherever it happened to be halted before
      if (!data[17]) begin
        $display("FAIL core not halted by vector catch: %08x", data);
        errors = errors + 1;
      end else begin
        $display("ok   vector catch halted core   %08x", data);
      end
      // derived from the loaded vector table rather than hardcoded, so the test
      // does not care where the linker happened to put the reset handler
      mem32_write(scs_base + 32'hdf4, 32'h0000_000f);  // read pc
      mem32_read(scs_base + 32'hdf8, data);
      expect32("pc at reset handler", data, fw_image[1] & 32'hffff_fffe);

      // and sp came from word 0 of the freshly loaded vector table
      mem32_write(scs_base + 32'hdf4, 32'h0000_000d);  // read sp
      mem32_read(scs_base + 32'hdf8, data);
      expect32("sp from vector table", data, fw_image[0]);
    end

    $display("");
    if (errors == 0) begin
      $display("PASS");
    end else begin
      $display("FAIL, %0d error(s)", errors);
    end
    $finish;
  end

  initial begin
    #40ms;
    $display("FAIL timeout");
    $finish;
  end

endmodule

`default_nettype wire

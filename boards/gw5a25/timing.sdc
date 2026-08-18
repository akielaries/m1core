// 50 MHz oscillator on the tang primer 25k
//
// one create_clock, on purpose. an earlier version also had set_false_path
// lines for SWCLK/SWDIO/HRST and the tool emitted an empty timing report, which
// is what a rejected sdc looks like. SWCLK needs no clock of its own: the phy
// oversamples it, so it never reaches a register clock pin
create_clock -name HCLK -period 20 -waveform {0 10} [get_ports {HCLK}]

// clk_sys is deliberately not declared. synthesis merges the assign in top.v
// away, so there is no object of that name left to constrain (TA2003). it is
// also redundant, since the tool derives the pll's outputs from the pll's own
// parameters. if one is ever genuinely missing, the selector is the instance
// pin rather than the net: [get_pins {u_pll/clkout0}]

// ---- the pll frequency picks which question you are asking ----
//
//   80    a build that closes. Fmax then reads as a floor, because the tool
//         stops optimising once the constraint is met
//   100   a measurement. it will not close and the Fmax is real. 87-88 for this
//         core, and 82.0/87.7 for gowin's own cortex-m1, were measured this way
//
// never compare an Fmax from one against an Fmax from the other

// ---- the reset synchroniser crossing is reported, not cut ----
//
// pll_lock is generated in HCLK and consumed in clk_sys by the two flop
// synchroniser in top.v, and shows as one hold violation on rst_sync_0/D. it is
// benign: lock rises once at power up, so the worst case is reset releasing a
// cycle later than it might have.
//
// cutting it needs the generated clock's name, and this tool rejects both the
// name its own report prints and the object that report lists:
//
//   TA2004 Cannot get clock with name
//     'u_pll/u_pll_0/PLLA_inst/CLKOUT0.default_gen_clk'   Clock Name column
//     'u_pll/u_pll_0/PLLA_inst/CLKOUT0'                   Objects column
//
// TA2004 aborts the run, so each attempt costs a build. untried, in rising
// order of confidence: a get_clocks wildcard; get_clocks -of_objects on the pll
// pin; or skip get_clocks and cut the endpoint the hold table names, with
// set_false_path -to [get_pins {rst_sync_0_s0/D}].
//
// not a bare -from [get_clocks {HCLK}] with no -to: that also cuts HCLK to
// HCLK, which is the pll's own init sequencer

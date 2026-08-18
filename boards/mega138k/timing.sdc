// 50 MHz oscillator on the tang primer 25k
//
// kept to a single create_clock on purpose. an earlier version also carried
// set_false_path lines for SWCLK/SWDIO/HRST and the tool produced an empty
// timing report, which is what a rejected sdc looks like. the acm gw5a25 build
// that places cleanly on this board also has exactly one line
//
// SWCLK is deliberately not declared as a clock: the phy oversamples it and
// detects edges, so it never reaches a register clock pin and there is no
// second clock domain to constrain
create_clock -name HCLK -period 20 -waveform {0 10} [get_ports {HCLK}]

// clk_sys is NOT declared here, and that is deliberate.
//
// it was, twice: as a generated clock while it was HCLK/2, and then as a
// create_clock once the pll arrived. the second form fails with
//
//   TA2003 Can't set timing constraint to object clk_sys
//   TA2004 Cannot get clock with name 'clk_sys'
//
// because top.v drives clk_sys with a plain assign from the pll output, and
// synthesis merges that net away. by the time constraints are read there is no
// object called clk_sys to attach anything to, and so nothing of that name to
// reference afterwards either.
//
// the fix is not a better selector. the constraint is redundant: the tool reads
// the pll's own parameters and derives its output clocks from them. FCLKIN 50,
// MDIV 18, ODIV0 9 is 100 MHz whether or not this file says so, and saying it
// again can only disagree.
//
// so the pll is where the system clock frequency is set, and this file follows
// rather than leads. check the report's Clock Summary for what was derived.
//
// ---- and that has a consequence worth knowing before you read an Fmax ----
//
// the pll is at 80 MHz now, which is what the part supports with margin, so
// this design is expected to MEET timing. once it does, "Actual Fmax" stops
// being a measurement: the tool stops trying as soon as the constraint is
// satisfied, and the number it prints is a floor rather than a ceiling. every
// early figure in this project (25.697, 33.394, 44) was a floor for exactly
// that reason, measured while the constraint asked for 25.
//
// so there are two modes, and you have to choose deliberately:
//
//   pll at 80   a build that closes. the deliverable. Fmax reads as a floor
//   pll at 100  a measurement. it will not close, and the reported Fmax is
//               real -- that is how 87-88 was established, and how gowin's own
//               cortex-m1 was measured at 82.0 and 87.7 on this same board
//
// if a derived clock is ever genuinely missing rather than just renamed, the
// selector that works is the instance pin, not the net:
//
//   create_clock -name clk_sys -period 10 [get_pins {u_pll/clkout0}]
//
// the divider era also needed a set_false_path from clk_sys to HCLK, cutting a
// hold check on the divider flop that the tool analysed across two clocks that
// were physically the same edge. no flop is clocked by HCLK any more, so that
// constraint left with the divider that caused it

// ---------------------------------------------------------------------------
// the reset synchroniser's clock domain crossing
//
// pll_lock is produced in the HCLK domain -- the generated wrapper clocks the
// pll's init sequencer from mdclk, which is HCLK, not the pll output -- and it
// is consumed in the clk_sys domain by the two flop reset synchroniser in
// top.v. that is a genuine crossing and the tool is right to report it.
//
// what it reports depends on how the crossing is written, and both forms have
// been built:
//
//   pll_lock as part of the asynchronous reset   two negative REMOVAL slacks
//                                                on rst_sync_0/CLEAR and
//                                                rst_sync_1/CLEAR
//   pll_lock as data into the synchroniser       one negative HOLD slack on
//                                                rst_sync_0/D, -1.127 ns
//
// the second is the current form and it is the textbook one. it is also
// benign, and it is worth being precise about why rather than asserting it:
// pll_lock goes low to high exactly once, at power up, and stays high. a hold
// violation there means rst_sync_0 may capture the old value or go metastable
// on the edge where lock rises. the next clock edge captures it cleanly, and
// rst_sync_1 is a second stage behind that. the observable consequence is that
// reset releases one cycle later than it might have. that is the entire risk,
// and it is what a synchroniser is for.
//
// gw5a25/timing.sdc HAS THIS CUT AND THIS ONE DOES NOT, deliberately. the
// constraint names the generated clock, and that name is device and pll
// specific -- this board's pll is not the 25k's primitive, so the name below is
// a guess until this board's own report prints one. take it from that report's
// Clock Summary, then uncomment.
//
// TO SILENCE IT PROPERLY, uncomment one of these. they are commented because
// this tool has previously answered a set_false_path by emitting an EMPTY
// timing report, which is what a rejected sdc looks like and is far worse than
// a reported non-problem. if you add one:
//
//   1. check the Clock Summary still lists BOTH clocks afterwards
//   2. check the path counts are still in the tens of thousands
//   3. if either is wrong, the constraint was rejected -- take it back out
//
// set_false_path -from [get_clocks {HCLK}] \
//                -to   [get_clocks {u_pll/u_pll_0/PLLA_inst/CLKOUT0.default_gen_clk}]
//
// the crossing above is the only HCLK to clk_sys path in the design: nothing
// else is clocked by HCLK except the pll's own init sequencer. so the blanket
// form is safe here in a way it would not be in a design with real logic in
// both domains

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
// rather than leads. check the report's Clock Summary for what was derived. if
// a derived clock is ever genuinely missing rather than just renamed, the
// selector that works is the instance pin, not the net:
//
//   create_clock -name clk_sys -period 10 [get_pins {u_pll/clkout0}]
//
// the divider era also needed a set_false_path from clk_sys to HCLK, cutting a
// hold check on the divider flop that the tool analysed across two clocks that
// were physically the same edge. no flop is clocked by HCLK any more, so that
// constraint left with the divider that caused it

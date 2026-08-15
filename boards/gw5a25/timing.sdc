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

// the mcu runs on HCLK divided by two, generated in top.v. without this the
// tool has no description of clk_sys and invents a relationship: the first
// build reported required=12.9 ns on a path between two clk_sys registers,
// which is neither the 20 ns nor the 40 ns period and is not a number any
// decision should be based on
create_generated_clock -name clk_sys -source [get_ports {HCLK}] -divide_by 2 \
    [get_nets {clk_sys}]

# non-project vivado build of m1core for the basys 3
#   vivado -mode batch -source build.tcl -tclargs <out dir>
# outputs: top.bit, post_route.dcp, reports/*.rpt

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here .. ..]]
set out  [file normalize [lindex $argv 0]]
set part xc7a35tcpg236-1

source [file join $here rtl.tcl]

file mkdir [file join $out reports]
foreach f $rtl {
  read_verilog [file join $root $f]
}
read_verilog [file join $here top.v]
read_xdc [file join $here basys3.xdc]

synth_design -top top -part $part
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $out post_route.dcp]

report_utilization       -file [file join $out reports util.rpt]
report_utilization -hierarchical -file [file join $out reports util_hier.rpt]
report_timing_summary    -file [file join $out reports timing.rpt]
report_drc               -file [file join $out reports drc.rpt]

write_bitstream -force [file join $out top.bit]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "RESULT: m1core basys3 wns=$wns"
if {$wns ne "" && $wns < 0} {
  puts "RESULT: timing NOT met"
  exit 2
}

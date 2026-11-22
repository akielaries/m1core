# create a vivado project (.xpr) for the gui. sources are referenced in place
#   vivado -mode batch -source project.tcl -tclargs <out dir>

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here .. ..]]
set out  [file normalize [lindex $argv 0]]
set part xc7a35tcpg236-1

source [file join $here rtl.tcl]

create_project -force m1core_basys3 [file join $out proj] -part $part
foreach f $rtl {
  add_files -norecurse [file join $root $f]
}
add_files -norecurse [file join $here top.v]
add_files -fileset constrs_1 -norecurse [file join $here basys3.xdc]
set_property top top [current_fileset]
update_compile_order -fileset sources_1

puts "RESULT: project at [file join $out proj m1core_basys3.xpr]"

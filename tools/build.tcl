# -----------------------------------------------------------------------------
# Non-interactive synthesis, implementation, bitstream and hardware platform for the NPU block
# design.
#
#   cd <repo root>
#   vivado -mode batch -nojournal -source tools/build.tcl
#
# Writes build/npu.bit, build/npu.hwh (the hardware handoff PYNQ loads with the bitstream) and
# build/npu.xsa (bitstream included), and the utilization and timing reports to reports/.
#
# Why this script exists rather than "open the project and hit Run":
#
#   * It creates fresh synth_2/impl_2 runs, so every build starts from the sources rather
#     than from the project's old synth_1 run.
#
#   * npu_top is a packaged user IP, so the IP catalog has to be pointed at
#     rtl/ before the block design can resolve it.
# -----------------------------------------------------------------------------

set repo  [file normalize [file join [file dirname [info script]] ..]]
set proj  $repo/vivado/npu.xpr
set out   $repo/build
set jobs  8

if {![file exists $proj]} { error "project not found: $proj" }
open_project $proj

# npu_top lives in rtl/component.xml
set_property ip_repo_paths [list $repo/rtl] [current_project]
update_ip_catalog -rebuild
if {![llength [get_ipdefs -quiet *npu_top*]]} {
    error "npu_top IP not found in $repo/rtl - is component.xml present?"
}

set bd [get_files -quiet npu_bd.bd]
if {$bd eq ""} { error "npu_bd.bd not found in the project" }

# Upgrade the block design's npu_top instance when rtl/component.xml is a newer core revision than
# the one the instance was made from (revision 3 widened the BRAM port-B address and write-enable
# pins). Vivado reports "upgrade not required" otherwise, which is caught like the notes below.
open_bd_design $bd
set npu_ip [get_ips -quiet -all *npu_top*]
if {[llength $npu_ip] && [catch {upgrade_ip $npu_ip} e]} {
    puts "NOTE: upgrade_ip reported: $e"
}
save_bd_design

# Regenerate the block design's output products. The BD 41-68 "addr.tcl"
# message some Vivado 2022.1 installs emit here is harmless - the output
# products are still written - so it is caught rather than allowed to abort.
if {[catch {generate_target all [get_files $bd]} e]} {
    puts "NOTE: generate_target reported: $e"
}
if {[catch {make_wrapper -files [get_files $bd] -top -force} e]} {
    puts "NOTE: make_wrapper reported: $e"
}

# add_files on the copy under .gen/ is silently skipped as a generated product,
# so stage the wrapper beside the project and add it from there.
set gen_wrapper $repo/vivado/npu.gen/sources_1/bd/npu_bd/hdl/npu_bd_wrapper.v
set wrapper     $repo/vivado/npu_bd_wrapper.v
if {![file exists $gen_wrapper]} { error "BD wrapper was not generated" }
file copy -force $gen_wrapper $wrapper
add_files -norecurse [list $wrapper]

update_compile_order -fileset sources_1
set_property TOP_AUTO_SET 0 [current_fileset]
set_property top npu_bd_wrapper [current_fileset]

foreach r {synth_2 impl_2} {
    if {[llength [get_runs -quiet $r]]} { delete_run $r }
}
create_run synth_2 -flow {Vivado Synthesis 2022}       -constrset constrs_1
create_run impl_2  -flow {Vivado Implementation 2022}  -parent_run synth_2 -constrset constrs_1

launch_runs synth_2 -jobs $jobs
wait_on_run synth_2
if {[get_property PROGRESS [get_runs synth_2]] != "100%"} {
    error "synthesis failed: [get_property STATUS [get_runs synth_2]]"
}

launch_runs impl_2 -to_step write_bitstream -jobs $jobs
wait_on_run impl_2
if {[get_property PROGRESS [get_runs impl_2]] != "100%"} {
    error "implementation failed: [get_property STATUS [get_runs impl_2]]"
}

# Reports, with the host name and absolute paths removed so they can be committed
proc write_clean_report {path} {
    global repo
    set fh [open $path r]
    set lines [split [read $fh] "\n"]
    close $fh
    set kept {}
    foreach l $lines {
        if {[string match "| Host*" $l]} { continue }
        lappend kept [string map [list "$repo/" ""] $l]
    }
    set fh [open $path w]
    puts -nonewline $fh [join $kept "\n"]
    close $fh
}

open_run impl_2
file mkdir $repo/reports
file mkdir $out
report_utilization    -file $repo/reports/npu_bd_wrapper_utilization_placed.rpt
report_timing_summary -file $repo/reports/npu_bd_wrapper_timing_summary_routed.rpt
write_clean_report $repo/reports/npu_bd_wrapper_utilization_placed.rpt
write_clean_report $repo/reports/npu_bd_wrapper_timing_summary_routed.rpt

# Bitstream (written by impl_2's write_bitstream step) and the hardware platform for PYNQ/Vitis
set bit [lindex [glob -nocomplain [get_property DIRECTORY [get_runs impl_2]]/*.bit] 0]
if {$bit eq ""} { error "impl_2 did not produce a bitstream" }
file copy -force $bit $out/npu.bit
write_hw_platform -fixed -include_bit -force -file $out/npu.xsa

# PYNQ's Overlay("npu.bit") reads the block design from npu.hwh in the same directory. Ask Vivado
# for the block design's hardware handoff, falling back to where 2022.1 generates it. If neither
# exists, the build still finishes and then fails below; npu.xsa (a zip) holds the same file.
file delete -force $out/npu.hwh
set hwh [lindex [get_files -quiet -all -of_objects [get_files $bd] *npu_bd.hwh] 0]
if {$hwh eq ""} { set hwh $repo/vivado/npu.gen/sources_1/bd/npu_bd/hw_handoff/npu_bd.hwh }
if {[file exists $hwh]} {
    file copy -force $hwh $out/npu.hwh
    set hwh_msg $out/npu.hwh
} else {
    set hwh_msg "NOT WRITTEN - extract npu_bd.hwh from $out/npu.xsa (a zip) as $out/npu.hwh"
}

puts "-----------------------------------------------------------------"
puts "black boxes : [llength [get_cells -hier -filter {IS_BLACKBOX==1}]]"
foreach c [get_clocks] {
    puts "clock       : $c  period [get_property PERIOD $c] ns"
}
puts "WNS         : [get_property SLACK [get_timing_paths -delay_type max]] ns"
puts "reports     : $repo/reports"
puts "bitstream   : $out/npu.bit"
puts "handoff     : $hwh_msg"
puts "platform    : $out/npu.xsa"
puts "-----------------------------------------------------------------"
if {![file exists $out/npu.hwh]} { error "npu.hwh was not written (see handoff above)" }

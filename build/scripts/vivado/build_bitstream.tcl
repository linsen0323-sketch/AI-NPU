# Explicit opt-in full hardware build. Uses only packaged sources.
source [file join [file dirname [info script]] create_project.tcl]
set npu_jobs 4
if {[info exists ::env(NPU_BUILD_JOBS)]} {set npu_jobs $::env(NPU_BUILD_JOBS)}
launch_runs synth_1 -jobs $npu_jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error {Synthesis did not complete}}
launch_runs impl_100mhz -to_step write_bitstream -jobs $npu_jobs
wait_on_run impl_100mhz
if {[get_property PROGRESS [get_runs impl_100mhz]] ne "100%"} {error {Implementation did not complete}}
open_run impl_100mhz
set npu_report_dir [file join $npu_root build work reports]
file mkdir $npu_report_dir
report_timing_summary -report_unconstrained -file [file join $npu_report_dir timing_routed.rpt]
report_utilization -file [file join $npu_report_dir utilization_routed.rpt]
report_route_status -file [file join $npu_report_dir route_status.rpt]
report_bus_skew -file [file join $npu_report_dir bus_skew_routed.rpt]
puts {Build finished. Review setup, hold, bus skew and constraints before using the new hardware.}

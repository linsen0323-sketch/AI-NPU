# Optional testbench setup after create_project.tcl; does not launch simulation.
set npu_root [file normalize [file join [file dirname [info script]] .. ..]]
if {[get_property NAME [current_project]] ne "npu100"} {error {Open the recreated npu100 project}}
if {[llength [get_filesets -quiet sim_camera_profile]] == 0} {create_fileset -simset sim_camera_profile}
add_files -fileset sim_camera_profile -norecurse [file join $npu_root sim rtl tb_ov5640_profile.sv]
set_property top tb_ov5640_profile [get_filesets sim_camera_profile]
set_property xsim.simulate.runtime 10us [get_filesets sim_camera_profile]
set_property top tb_ai_result_overlay [get_filesets sim_1]
update_compile_order -fileset sim_1
update_compile_order -fileset sim_camera_profile
puts {Simulation filesets configured. No simulation was launched.}

# Export from a successfully built packaged project; does not rebuild hardware.
set npu_root [file normalize [file join [file dirname [info script]] .. .. ..]]
if {[llength [get_projects -quiet]] == 0} {
    if {[info exists ::env(NPU_BUILD_DIR)]} {set npu_dir [file normalize $::env(NPU_BUILD_DIR)]} else {set npu_dir [file join $npu_root build work vivado]}
    open_project [file join $npu_dir npu100.xpr]
}
if {[get_property NAME [current_project]] ne "npu100"} {error {Expected project npu100}}
open_run impl_100mhz
set npu_export [file join $npu_root build work hardware]
file mkdir $npu_export
write_hw_platform -fixed -include_bit -force -file [file join $npu_export npu100.xsa]
puts "NEW_XSA=[file join $npu_export npu100.xsa]"

# Configure recovered npu100 module-level testbenches. Does not launch simulation.
set npu_unit_root [file normalize [file join [file dirname [info script]] .. .. ..]]
if {[get_property NAME [current_project]] ne "npu100"} {error {Open the recreated npu100 project first}}
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
foreach {suite top reference} {
    wbuf tb_wbuf_native {}
    dma tb_dma_nonempty reference/npu_stream_dma_before.sv
    round tb_round_miter reference/round_before.sv
    maxpool_bulk tb_maxpool_source_words_bulk reference/npu_maxpool_engine_before.sv
    maxpool_scalar tb_maxpool_source_words_scalar reference/npu_maxpool_engine_before.sv
} {
    set source_suite $suite
    if {[string match maxpool_* $suite]} {set source_suite maxpool}
    set fileset sim_unit_$suite
    if {[llength [get_filesets -quiet $fileset]] == 0} {create_fileset -simset $fileset}
    set suite_dir [file join $npu_unit_root sim rtl unit $source_suite]
    add_files -fileset $fileset -norecurse [file join $suite_dir testbench.sv]
    if {$reference ne ""} {add_files -fileset $fileset -norecurse [file join $suite_dir $reference]}
    if {$suite eq "dma"} {
        add_files -fileset $fileset -norecurse [file join $suite_dir dma_environment.svh]
        set_property include_dirs [list $suite_dir] [get_filesets $fileset]
    }
    set_property top $top [get_filesets $fileset]
    set_property xsim.simulate.runtime 30ms [get_filesets $fileset]
    update_compile_order -fileset $fileset
}
puts "NPU_UNIT_FILESETS=[get_filesets sim_unit_*]"
puts {Recovered module testbenches configured; simulation was not launched.}


# Read a successful drained task and publish its dump plus matching identity.
# Requires load_graph.tcl in this XSDB session. Does not reset/relaunch/start.
source [file join [file dirname [info script]] model_config.tcl]
foreach key {AI_GRAPH_BASE AI_WORKSPACE_BASE NPUG_STAGED_RECEIPT NPUG_DDR_SHA256 NPUG_INPUT_SHA256} {
    if {![info exists ::$key]} {error "Missing $key; stage with matching load_graph.tcl in this session"}
}
proc ::npug_read_result_word {address} {
    set data [mrd -value $address 1]
    if {[llength $data]!=1 || ![string is wideinteger -strict [lindex $data 0]]} {error "Expected one integer MMIO word"}
    return [expr {wide([lindex $data 0])&0xffffffff}]
}
proc ::npug_result_snapshot {} {
    set result [dict create]
    foreach {name offset} {control 4 status 12 model_base 16 workspace_base 24 fault 48 model_id 52 task_id 56 frame_id 64 model_generation 68 output_addr 108 output_bytes 112 output_dtype 116 result_valid 120} {
        dict set result $name [::npug_read_result_word [expr {$::AI_GRAPH_BASE+$offset}]]
    }
    if {[dict get $result status]!=2 || [dict get $result result_valid]!=1 || [dict get $result control]!=0 || [dict get $result fault]!=0} {
        error "A successful drained task with no pending START/cancel/invalidate is required"
    }
    return $result
}
set task_folder [file dirname [info script]]
set task_path [file join $task_folder output.bin]
set task_meta [file join $task_folder output_metadata.json]
# Do not leave an old identity file beside a failed or partial new dump.
file delete -force $task_meta
if {[::npug_read_result_word $::AI_GRAPH_BASE]!=0x4e475031} {error "Graph register ID mismatch"}
set task_before [::npug_result_snapshot]
foreach {key value} $::NPUG_STAGED_RECEIPT {
    if {$key in {ddr_sha256 input_sha256}} {continue}
    if {[dict get $task_before $key]!=$value} {error "Result differs from staged receipt: $key"}
}
if {[dict get $::NPUG_STAGED_RECEIPT model_id]!=$::NPUG_MODEL_ID ||
    [dict get $::NPUG_STAGED_RECEIPT workspace_base]!=$::AI_WORKSPACE_BASE ||
    [dict get $::NPUG_STAGED_RECEIPT ddr_sha256] ne $::NPUG_DDR_SHA256 ||
    [dict get $::NPUG_STAGED_RECEIPT input_sha256] ne $::NPUG_INPUT_SHA256} {error "Result configuration differs from staged model/input"}
set handle [open "$task_path.tmp" wb];fconfigure $handle -translation binary -encoding binary
set task_crc 0
try {
    for {set offset 0} {$offset<$::NPUG_OUTPUT_BYTES} {incr offset 1048576} {
        set length [expr {min(1048576,$::NPUG_OUTPUT_BYTES-$offset)}]
        set data [mrd -size w -bin [expr {[dict get $task_before output_addr]+$offset}] [expr {$length/4}]]
        if {[string length $data]!=$length} {error "Short output read"}
        puts -nonewline $handle $data
        set task_crc [zlib crc32 $data $task_crc]
    }
} finally {close $handle}
set task_after [::npug_result_snapshot]
if {$task_before ne $task_after} {error "Task identity/state changed during output read; dump was not published"}
set handle [open "$task_meta.tmp" w]
try {
    puts $handle [format {{
  "format": "NPUPLN1_RESULT_V1",
  "model_id": %u, "task_id": %u, "frame_id": %u, "model_generation": %u,
  "status": 2, "fault": 0,
  "ddr_sha256": "%s", "input_sha256": "%s",
  "output_dtype": %u, "output_bytes": %u, "output_crc32": %u
}} [dict get $task_before model_id] [dict get $task_before task_id] [dict get $task_before frame_id] \
        [dict get $task_before model_generation] $::NPUG_DDR_SHA256 $::NPUG_INPUT_SHA256 \
        [dict get $task_before output_dtype] [dict get $task_before output_bytes] [expr {$task_crc&0xffffffff}]]
} finally {close $handle}
file rename -force "$task_path.tmp" $task_path
file rename -force "$task_meta.tmp" $task_meta
puts "Saved $task_path and $task_meta. Compare with tools/compare_graph_output.py; values are not checked here."

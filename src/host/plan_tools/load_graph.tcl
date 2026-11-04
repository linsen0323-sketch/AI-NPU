# Generated model folders copy this script alongside model_config.tcl/ddr.bin.
# Source only AFTER the matching bitstream and PS DDR initialization. No reset,
# FPGA programming, CPU resume or automatic inference is performed here.
source [file join [file dirname [info script]] model_config.tcl]
if {![info exists ::NPUG_MODEL_ID] || $::NPUG_MODEL_ID ni {1 3}} {
    error "Production graph loading supports only ResNet18 ID 1 and YOLOX ID 3"
}
# A failed/replaced staging attempt must not reuse the previous input identity.
unset -nocomplain ::NPUG_STAGED_RECEIPT
foreach key {AI_MODEL_BASE AI_WORKSPACE_BASE AI_DDR_BEGIN AI_DDR_END AI_RESERVED_BEGIN AI_RESERVED_END AI_DDR_EXCLUSIVE NPUG_DDR_SHA256 NPUG_INPUT_SHA256} {
    if {![info exists ::$key]} {error "Set $key before staging graph data"}
}
if {$::AI_DDR_EXCLUSIVE!=1} {error "Reserve these DDR ranges from CPU, DMA and any future Linux allocator"}
if {![info exists ::AI_GRAPH_BASE]} {set ::AI_GRAPH_BASE 0x43C18000}
if {![info exists ::AI_MODEL_GENERATION]} {set ::AI_MODEL_GENERATION 1}
if {![info exists ::AI_FRAME_ID]} {set ::AI_FRAME_ID 0}
set task_cpu_state [state]
if {$task_cpu_state ne "Stopped" && ![string match "Stopped: (*)" $task_cpu_state]} {error "Stop the selected Cortex-A9 first; this script does not stop/reset it"}
namespace eval ::npu_launch {
    proc read32 {address} {
        set data [mrd -value $address 1]
        if {[llength $data]!=1 || ![string is wideinteger -strict [lindex $data 0]]} {error "Expected one integer MMIO word at $address"}
        return [expr {wide([lindex $data 0]) & 0xffffffff}]
    }
    proc poll {address mask expected timeout_ms} {
        set deadline [expr {[clock milliseconds]+$timeout_ms}]
        while {1} {
            if {([read32 $address]&$mask)==$expected} {return}
            if {[clock milliseconds]>=$deadline} {error "Timed out waiting at [format 0x%08X $address]; DDR remains owned until the engine drains"}
            after 20
        }
    }
    proc input_crc {base bytes expected} {
        set crc 0
        for {set offset 0} {$offset<$bytes} {incr offset 1048576} {
            set length [expr {min(1048576,$bytes-$offset)}]
            set data [mrd -size w -bin [expr {$base+$offset}] [expr {$length/4}]]
            if {[string length $data]!=$length} {error "Short input readback"}
            set crc [zlib crc32 $data $crc]
        }
        if {($crc&0xffffffff)!=$expected} {error "Input DDR CRC mismatch; inference was not started"}
    }
}
set task_model_end [expr {wide($::AI_MODEL_BASE)+$::NPUG_DDR_BYTES}]
set task_work_end [expr {wide($::AI_WORKSPACE_BASE)+$::NPUG_WORKSPACE_BYTES}]
if {$::AI_MODEL_BASE%4096 || $::AI_WORKSPACE_BASE%4096 ||
    $::AI_MODEL_BASE<$::AI_DDR_BEGIN || $::AI_WORKSPACE_BASE<$::AI_DDR_BEGIN ||
    $task_model_end>$::AI_DDR_END || $task_work_end>$::AI_DDR_END ||
    $::AI_MODEL_BASE<$::AI_RESERVED_BEGIN || $::AI_WORKSPACE_BASE<$::AI_RESERVED_BEGIN ||
    $task_model_end>$::AI_RESERVED_END || $task_work_end>$::AI_RESERVED_END ||
    $task_model_end>0x100000000 || $task_work_end>0x100000000 ||
    ($::AI_MODEL_BASE<$task_work_end && $::AI_WORKSPACE_BASE<$task_model_end)} {error "Invalid, overlapping or unreserved DDR ranges"}
if {[::npu_launch::read32 $::AI_GRAPH_BASE]!=0x4e475031} {error "NPUPLN1 graph registers absent; use the matching new hardware"}
if {[::npu_launch::read32 [expr {$::AI_GRAPH_BASE+0x88}]]!=2} {error "Unified camera graph extension version 2 is required; refresh the matching bitstream"}
if {[::npu_launch::read32 [expr {$::AI_GRAPH_BASE+0xdc}]]!=10} {
    error "Matching ResNet18/YOLOX two-model hardware is required"
}
if {([::npu_launch::read32 [expr {$::AI_GRAPH_BASE+0x0c}]]&1)!=0 ||
    ([::npu_launch::read32 [expr {$::AI_GRAPH_BASE+4}]]&1)!=0} {error "Graph task/pending START still owns DDR"}
if {([::npu_launch::read32 [expr {$::AI_GRAPH_BASE+0x0c}]]&2)!=0} {
    mwr [expr {$::AI_GRAPH_BASE+4}] 4
    ::npu_launch::poll [expr {$::AI_GRAPH_BASE+0x0c}] 2 0 10000
    ::npu_launch::poll [expr {$::AI_GRAPH_BASE+0x78}] 1 0 10000
}
mwr [expr {$::AI_GRAPH_BASE+8}] 1
::npu_launch::poll [expr {$::AI_GRAPH_BASE+8}] 0x06 0x06 60000
mwr [expr {$::AI_GRAPH_BASE+4}] 8
::npu_launch::poll [expr {$::AI_GRAPH_BASE+4}] 8 0 10000
set task_folder [file dirname [info script]]
set task_image [file join $task_folder ddr.bin]
set task_input [file join $task_folder input.bin]
foreach {filename expected_bytes expected_crc} [list $task_image $::NPUG_DDR_BYTES $::NPUG_DDR_CRC $task_input $::NPUG_INPUT_BYTES $::NPUG_INPUT_CRC] {
    set handle [open $filename rb];set data [read $handle];close $handle
    if {[string length $data]!=$expected_bytes || ([zlib crc32 $data]&0xffffffff)!=$expected_crc} {error "Local staging file differs from model configuration: $filename"}
}
dow -data $task_image $::AI_MODEL_BASE
dow -data $task_input [expr {$::AI_WORKSPACE_BASE+$::NPUG_INPUT_OFFSET}]
::npu_launch::input_crc [expr {$::AI_WORKSPACE_BASE+$::NPUG_INPUT_OFFSET}] $::NPUG_INPUT_BYTES $::NPUG_INPUT_CRC
foreach {offset value} [list 0x10 $::AI_MODEL_BASE 0x14 $::NPUG_DDR_BYTES 0x18 $::AI_WORKSPACE_BASE 0x1c $::NPUG_WORKSPACE_BYTES \
    0x20 [expr {$::AI_MODEL_BASE+$::NPUG_PLAN_OFFSET}] 0x24 $::NPUG_PLAN_BYTES 0x28 $::AI_FRAME_ID 0x2c $::AI_MODEL_GENERATION \
    0x60 [expr {$::AI_WORKSPACE_BASE+$::NPUG_OUTPUT_OFFSET}] 0x64 $::NPUG_OUTPUT_BYTES 0x68 $::NPUG_OUTPUT_DTYPE] {
    mwr [expr {$::AI_GRAPH_BASE+$offset}] $value
}
set ::NPUG_STAGED_RECEIPT [dict create model_id $::NPUG_MODEL_ID ddr_sha256 $::NPUG_DDR_SHA256 \
    input_sha256 $::NPUG_INPUT_SHA256 model_base $::AI_MODEL_BASE workspace_base $::AI_WORKSPACE_BASE \
    frame_id $::AI_FRAME_ID model_generation $::AI_MODEL_GENERATION \
    output_addr [expr {$::AI_WORKSPACE_BASE+$::NPUG_OUTPUT_OFFSET}] output_bytes $::NPUG_OUTPUT_BYTES \
    output_dtype $::NPUG_OUTPUT_DTYPE]
puts "Staged $::NPUG_MODEL_NAME; source model/plan will be checked by PL on START. No inference was started."
puts "Start: mwr [format 0x%08X [expr {$::AI_GRAPH_BASE+4}]] 5"
puts "Status: mrd [format 0x%08X [expr {$::AI_GRAPH_BASE+0x0c}]]; op index: mrd [format 0x%08X [expr {$::AI_GRAPH_BASE+0x3c}]]"

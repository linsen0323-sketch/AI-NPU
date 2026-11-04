# Recreate only the final npu100 design. Does not synthesize or implement.
# Requires Vivado 2025.2 with xc7z020 device support.
set npu_root [file normalize [file join [file dirname [info script]] .. .. ..]]
if {[llength [get_projects -quiet]] != 0} {error {Close the current project before recreation}}
if {[version -short] ne "2025.2"} {error {This snapshot requires Vivado 2025.2; port and validate other releases explicitly}}
if {[info exists ::env(NPU_BUILD_DIR)]} {
    set npu_project_dir [file normalize $::env(NPU_BUILD_DIR)]
} else {
    set npu_project_dir [file join $npu_root build work vivado]
}
if {[file exists [file join $npu_project_dir npu100.xpr]]} {error "Project already exists: $npu_project_dir/npu100.xpr"}
file mkdir $npu_project_dir
create_project npu100 $npu_project_dir -part xc7z020clg400-2
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
set npu_sources {
    src/hardware/rtl/accelerator/npu_axil_window_mux.sv
    src/hardware/rtl/video/ai_camera_pipeline.sv
    src/hardware/rtl/video/ai_dma64.sv
    src/hardware/rtl/video/ai_frame_scanout.sv
    src/hardware/rtl/video/ai_preprocess_top.sv
    src/hardware/rtl/video/ai_result_overlay.sv
    src/hardware/rtl/video/ai_snapshot.sv
    src/hardware/rtl/accelerator/npu_aipkg3_frontend.sv
    src/hardware/rtl/accelerator/npu_banked_buffer.sv
    src/hardware/rtl/accelerator/npu_conv2d_stream_engine.sv
    src/hardware/rtl/accelerator/npu_conv_epilogue.sv
    src/hardware/rtl/accelerator/npu_conv_output_tile.sv
    src/hardware/rtl/accelerator/npu_copy_engine.sv
    src/hardware/rtl/accelerator/npu_copy_stream_engine.sv
    src/hardware/rtl/accelerator/npu_dsp48_pair.sv
    src/hardware/rtl/accelerator/npu_graph_control_top.sv
    src/hardware/rtl/accelerator/npu_graph_plan_backend.sv
    src/hardware/rtl/accelerator/npu_graph_registers.sv
    src/hardware/rtl/accelerator/npu_graph_result_bridge.sv
    src/hardware/rtl/accelerator/npu_graph_sequencer.sv
    src/hardware/rtl/accelerator/npu_input_tile_loader.sv
    src/hardware/rtl/accelerator/npu_layer_profiler.sv
    src/hardware/rtl/accelerator/npu_lut_reader.sv
    src/hardware/rtl/accelerator/npu_maxpool_engine.sv
    src/hardware/rtl/accelerator/npu_model_control_top.sv
    src/hardware/rtl/accelerator/npu_package_cache.sv
    src/hardware/rtl/accelerator/npu_pe_8x32.sv
    src/hardware/rtl/accelerator/npu_plan_dispatch.sv
    src/hardware/rtl/accelerator/npu_plan_iterator.sv
    src/hardware/rtl/accelerator/npu_predecoded_frontend.sv
    src/hardware/rtl/accelerator/npu_predecoded_iterator.sv
    src/hardware/rtl/accelerator/npu_q16_elementwise.sv
    src/hardware/rtl/accelerator/npu_q16_scalar_engine.sv
    src/hardware/rtl/accelerator/npu_q16_vector_engine.sv
    src/hardware/rtl/accelerator/npu_q16_vector_pipe.sv
    src/hardware/rtl/accelerator/npu_resnet_gap_engine.sv
    src/hardware/rtl/accelerator/npu_resnet_quant.sv
    src/hardware/rtl/accelerator/npu_scalar_fabric.sv
    src/hardware/rtl/accelerator/npu_scalar_guard.sv
    src/hardware/rtl/accelerator/npu_shared_pe.sv
    src/hardware/rtl/accelerator/npu_stream_axi_master.sv
    src/hardware/rtl/accelerator/npu_stream_dma.sv
    src/hardware/rtl/accelerator/npu_stream_guard.sv
    src/hardware/rtl/accelerator/npu_stream_ibuf.sv
    src/hardware/rtl/accelerator/npu_stream_read_fabric.sv
    src/hardware/rtl/accelerator/npu_stream_weight_loader.sv
    src/hardware/rtl/accelerator/npu_stream_write_fabric.sv
    src/hardware/rtl/accelerator/npu_task_controller.sv
    src/hardware/rtl/accelerator/npu_wide_math.sv
    src/hardware/rtl/accelerator/npu_wide_math_fast.sv
    src/hardware/rtl/video/ai_camera_pipeline_bd.v
    src/hardware/rtl/video/cam_xclk_gen.v
    src/hardware/rtl/video/clock_gen_720p.v
    src/hardware/rtl/video/dvi_encoder.v
    src/hardware/rtl/video/dvi_transmitter_top.v
    src/hardware/rtl/video/dvp_to_axis.v
    src/hardware/rtl/video/ov5640_720p_rom.v
    src/hardware/rtl/video/ov5640_sccb_ctrl.v
    src/hardware/rtl/video/serializer_10_to_1.v
    src/hardware/rtl/video/camera_720p30_top.v
}
set npu_source_paths {}
foreach relative $npu_sources {
    set path [file join $npu_root $relative]
    if {![file isfile $path]} {error "Missing source: $relative"}
    lappend npu_source_paths $path
}
add_files -norecurse $npu_source_paths
set_property include_dirs [list [file join $npu_root src hardware rtl accelerator] [file join $npu_root src hardware rtl video]] [get_filesets sources_1]
set_property verilog_define {AI_PREPROCESS_PRESENT AI_PIPELINE_PRESENT} [get_filesets sources_1]
set_property top camera_720p30_top [get_filesets sources_1]
foreach name {navigator_720p.xdc camera_cdc_late.xdc} {
    add_files -fileset constrs_1 -norecurse [file join $npu_root src hardware constraints $name]
}
set npu_cdc [get_files */camera_cdc_late.xdc]
set_property used_in_synthesis false $npu_cdc
set_property processing_order LATE $npu_cdc
source [file join $npu_root src hardware block_design create_video_system.tcl]
set npu_bd [get_files */video_system.bd]
if {[llength $npu_bd] != 1} {error {Expected exactly one video_system.bd}}
open_bd_design $npu_bd
validate_bd_design
foreach clock_name {PCW_FPGA0_PERIPHERAL_FREQMHZ PCW_FPGA1_PERIPHERAL_FREQMHZ} {
    if {abs([get_property CONFIG.$clock_name [get_bd_cells ps7]] - 100.0) > 0.001} {error "Expected 100 MHz $clock_name"}
}
foreach {feature expected} {ENABLE_PE_SPATIAL4 1 ENABLE_LUT_TDP 1 ENABLE_PERF_COUNTERS 0 ENABLE_PROFILE_TRACE 0 ENABLE_STALL_DIAG 0} {
    if {[get_property CONFIG.$feature [get_bd_cells ai_preprocess_0]] != $expected} {error "Unexpected NPU feature $feature"}
}
save_bd_design
generate_target all $npu_bd
set npu_wrapper [make_wrapper -files $npu_bd -top]
add_files -norecurse $npu_wrapper
create_ip_run $npu_bd
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE AreaOptimized_medium [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.CONTROL_SET_OPT_THRESHOLD 16 [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.MAX_DSP 150 [get_runs synth_1]
create_run impl_100mhz -parent_run synth_1 -flow {Vivado Implementation 2025} -strategy {Vivado Implementation Defaults} -constrset constrs_1
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_100mhz]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_100mhz]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_100mhz]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_100mhz]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED false [get_runs impl_100mhz]
current_run -implementation [get_runs impl_100mhz]
add_files -fileset sim_1 -norecurse [file join $npu_root sim rtl tb_ai_result_overlay.sv]
set_property top tb_ai_result_overlay [get_filesets sim_1]
update_compile_order -fileset sources_1
puts "NPU_PROJECT_CREATED=[file join $npu_project_dir npu100.xpr]"
puts {RECREATION ONLY: synthesis, implementation and board execution were not run.}

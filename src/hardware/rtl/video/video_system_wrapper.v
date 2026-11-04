//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2 (win64) Build 6299465 Fri Nov 14 19:35:11 GMT 2025
//Date        : Sat Oct 31 19:19:47 2026
//Host        : LAPTOP-TKBH5FBB running 64-bit major release  (build 9200)
//Command     : generate_target video_system_wrapper.bd
//Design      : video_system_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module video_system_wrapper
   (AI_bad_count,
    AI_capture_run,
    AI_good_count,
    AI_keys_n,
    AI_source_frame,
    AI_tap_data,
    AI_tap_eol,
    AI_tap_fire,
    AI_tap_sof,
    AI_tensor_pending,
    DDR_addr,
    DDR_ba,
    DDR_cas_n,
    DDR_ck_n,
    DDR_ck_p,
    DDR_cke,
    DDR_cs_n,
    DDR_dm,
    DDR_dq,
    DDR_dqs_n,
    DDR_dqs_p,
    DDR_odt,
    DDR_ras_n,
    DDR_reset_n,
    DDR_we_n,
    FIXED_IO_ddr_vrn,
    FIXED_IO_ddr_vrp,
    FIXED_IO_mio,
    FIXED_IO_ps_clk,
    FIXED_IO_ps_porb,
    FIXED_IO_ps_srstb,
    axi_clk,
    axi_resetn,
    captured_frames,
    control,
    hdmi_locked,
    pixel_clk,
    reset_req,
    sensor_frames,
    status,
    video_data,
    video_de,
    video_hsync,
    video_locked,
    video_overflow,
    video_underflow,
    video_vsync);
  input [31:0]AI_bad_count;
  input AI_capture_run;
  input [31:0]AI_good_count;
  input [1:0]AI_keys_n;
  input [31:0]AI_source_frame;
  input [15:0]AI_tap_data;
  input AI_tap_eol;
  input AI_tap_fire;
  input AI_tap_sof;
  output AI_tensor_pending;
  inout [14:0]DDR_addr;
  inout [2:0]DDR_ba;
  inout DDR_cas_n;
  inout DDR_ck_n;
  inout DDR_ck_p;
  inout DDR_cke;
  inout DDR_cs_n;
  inout [3:0]DDR_dm;
  inout [31:0]DDR_dq;
  inout [3:0]DDR_dqs_n;
  inout [3:0]DDR_dqs_p;
  inout DDR_odt;
  inout DDR_ras_n;
  inout DDR_reset_n;
  inout DDR_we_n;
  inout FIXED_IO_ddr_vrn;
  inout FIXED_IO_ddr_vrp;
  inout [53:0]FIXED_IO_mio;
  inout FIXED_IO_ps_clk;
  inout FIXED_IO_ps_porb;
  inout FIXED_IO_ps_srstb;
  output axi_clk;
  output [0:0]axi_resetn;
  input [31:0]captured_frames;
  output [31:0]control;
  input hdmi_locked;
  input pixel_clk;
  input reset_req;
  input [31:0]sensor_frames;
  input [31:0]status;
  output [15:0]video_data;
  output video_de;
  output video_hsync;
  output video_locked;
  output video_overflow;
  output video_underflow;
  output video_vsync;

  wire [31:0]AI_bad_count;
  wire AI_capture_run;
  wire [31:0]AI_good_count;
  wire [1:0]AI_keys_n;
  wire [31:0]AI_source_frame;
  wire [15:0]AI_tap_data;
  wire AI_tap_eol;
  wire AI_tap_fire;
  wire AI_tap_sof;
  wire AI_tensor_pending;
  wire [14:0]DDR_addr;
  wire [2:0]DDR_ba;
  wire DDR_cas_n;
  wire DDR_ck_n;
  wire DDR_ck_p;
  wire DDR_cke;
  wire DDR_cs_n;
  wire [3:0]DDR_dm;
  wire [31:0]DDR_dq;
  wire [3:0]DDR_dqs_n;
  wire [3:0]DDR_dqs_p;
  wire DDR_odt;
  wire DDR_ras_n;
  wire DDR_reset_n;
  wire DDR_we_n;
  wire FIXED_IO_ddr_vrn;
  wire FIXED_IO_ddr_vrp;
  wire [53:0]FIXED_IO_mio;
  wire FIXED_IO_ps_clk;
  wire FIXED_IO_ps_porb;
  wire FIXED_IO_ps_srstb;
  wire axi_clk;
  wire [0:0]axi_resetn;
  wire [31:0]captured_frames;
  wire [31:0]control;
  wire hdmi_locked;
  wire pixel_clk;
  wire reset_req;
  wire [31:0]sensor_frames;
  wire [31:0]status;
  wire [15:0]video_data;
  wire video_de;
  wire video_hsync;
  wire video_locked;
  wire video_overflow;
  wire video_underflow;
  wire video_vsync;

  video_system video_system_i
       (.AI_bad_count(AI_bad_count),
        .AI_capture_run(AI_capture_run),
        .AI_good_count(AI_good_count),
        .AI_keys_n(AI_keys_n),
        .AI_source_frame(AI_source_frame),
        .AI_tap_data(AI_tap_data),
        .AI_tap_eol(AI_tap_eol),
        .AI_tap_fire(AI_tap_fire),
        .AI_tap_sof(AI_tap_sof),
        .AI_tensor_pending(AI_tensor_pending),
        .DDR_addr(DDR_addr),
        .DDR_ba(DDR_ba),
        .DDR_cas_n(DDR_cas_n),
        .DDR_ck_n(DDR_ck_n),
        .DDR_ck_p(DDR_ck_p),
        .DDR_cke(DDR_cke),
        .DDR_cs_n(DDR_cs_n),
        .DDR_dm(DDR_dm),
        .DDR_dq(DDR_dq),
        .DDR_dqs_n(DDR_dqs_n),
        .DDR_dqs_p(DDR_dqs_p),
        .DDR_odt(DDR_odt),
        .DDR_ras_n(DDR_ras_n),
        .DDR_reset_n(DDR_reset_n),
        .DDR_we_n(DDR_we_n),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
        .FIXED_IO_mio(FIXED_IO_mio),
        .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb(FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
        .axi_clk(axi_clk),
        .axi_resetn(axi_resetn),
        .captured_frames(captured_frames),
        .control(control),
        .hdmi_locked(hdmi_locked),
        .pixel_clk(pixel_clk),
        .reset_req(reset_req),
        .sensor_frames(sensor_frames),
        .status(status),
        .video_data(video_data),
        .video_de(video_de),
        .video_hsync(video_hsync),
        .video_locked(video_locked),
        .video_overflow(video_overflow),
        .video_underflow(video_underflow),
        .video_vsync(video_vsync));
endmodule

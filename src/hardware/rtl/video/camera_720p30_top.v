
`timescale 1ns / 1ps
// Navigator Zynq-7020
// RGB565 capture and matched AI-result HDMI only.

module camera_720p30_top (
    input wire sys_clk, input wire sys_rst_n,
    input wire [1:0] pl_keys_n,
    input wire cam_pclk, input wire cam_vsync, input wire cam_href,
    input wire [7:0] cam_data,
    inout wire cam_scl, inout wire cam_sda,
    output wire cam_xclk, output wire cam_rst_n, output wire cam_pwdn,

    output wire tmds_clk_p, output wire tmds_clk_n,
    output wire [2:0] tmds_data_p, output wire [2:0] tmds_data_n,

    inout wire [14:0] DDR_addr, inout wire [2:0] DDR_ba,
    inout wire DDR_cas_n, DDR_ck_n, DDR_ck_p, DDR_cke, DDR_cs_n,
    inout wire [3:0] DDR_dm, inout wire [31:0] DDR_dq,
    inout wire [3:0] DDR_dqs_n, DDR_dqs_p,
    inout wire DDR_odt, DDR_ras_n, DDR_reset_n, DDR_we_n,
    inout wire FIXED_IO_ddr_vrn, FIXED_IO_ddr_vrp,
    inout wire [53:0] FIXED_IO_mio,
    inout wire FIXED_IO_ps_clk, FIXED_IO_ps_porb,
    inout wire FIXED_IO_ps_srstb
);

    wire pixel_clk, pixel_clk_5x, hdmi_locked, xclk_locked;

    clock_gen_720p u_hdmi_clk (
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .pixel_clk(pixel_clk),
        .pixel_clk_5x(pixel_clk_5x),
        .locked(hdmi_locked)
    );

    cam_xclk_gen u_xclk (
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .cam_xclk(cam_xclk),
        .locked(xclk_locked)
    );

    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *)
    reg [1:0] sys_reset_sync;

    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *)
    reg [1:0] pixel_reset_sync;

    wire pixel_arstn = sys_rst_n && hdmi_locked;

    always @(posedge sys_clk or negedge sys_rst_n)
        if (!sys_rst_n)
            sys_reset_sync <= 0;
        else
            sys_reset_sync <= {sys_reset_sync[0], 1'b1};

    always @(posedge pixel_clk or negedge pixel_arstn)
        if (!pixel_arstn)
            pixel_reset_sync <= 0;
        else
            pixel_reset_sync <= {pixel_reset_sync[0], 1'b1};

    wire init_done, init_failed, nack_seen;
    wire [8:0] config_index;
    wire [7:0] verify_index, diag_expected, diag_readback;
    wire [15:0] diag_reg, retry_count;
    wire [3:0] diag_error;

    ov5640_sccb_ctrl u_camera (
        .clk_50m(sys_clk),
        .reset_n(sys_reset_sync[1]),
        .xclk_locked(xclk_locked),
        .cam_scl(cam_scl),
        .cam_sda(cam_sda),
        .cam_rst_n(cam_rst_n),
        .cam_pwdn(cam_pwdn),
        .init_done(init_done),
        .init_failed(init_failed),
        .nack_seen(nack_seen),
        .config_index(config_index),
        .verify_index(verify_index),
        .diag_reg(diag_reg),
        .diag_expected(diag_expected),
        .diag_readback(diag_readback),
        .diag_error(diag_error),
        .retry_count(retry_count)
    );

    wire axi_clk, axi_resetn;
    wire [31:0] control, status;
    wire [15:0] axis_rgb, video_data;
    wire [1:0] axis_keep;
    wire axis_user, axis_last, axis_valid, axis_ready;
    // Camera capture is a free-running sink; snapshots claim whole frames.
    assign axis_ready = 1'b1;

    wire capture_active, recovery_required;
    wire overflow_sticky, format_error_sticky;
    wire frame_done_toggle, frame_error_toggle;
    wire stream_ready, sampled_vsync;
    wire [31:0] good_frames, bad_frames;
    wire [3:0] last_error;

    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *)
    reg [3:0] sensor_status_meta, sensor_status_sync;

    always @(posedge axi_clk or negedge axi_resetn)
        if (!axi_resetn) begin
            sensor_status_meta <= 0;
            sensor_status_sync <= 0;
        end else begin
            sensor_status_meta <= {
                hdmi_locked, nack_seen, init_failed, init_done
            };
            sensor_status_sync <= sensor_status_meta;
        end

    dvp_to_axis #(
    .IMAGE_WIDTH(1280),
    .IMAGE_HEIGHT(720)
        ) u_capture (
        .aresetn(axi_resetn),
        .stream_resetn(control[1]),
        .capture_enable(control[0] && sensor_status_sync[0]),
        .cam_pclk(cam_pclk),
        .cam_vsync(cam_vsync),
        .cam_href(cam_href),
        .cam_data(cam_data),
        .axi_clk(axi_clk),
        .m_axis_tdata(axis_rgb),
        .m_axis_tkeep(axis_keep),
        .m_axis_tuser(axis_user),
        .m_axis_tlast(axis_last),
        .m_axis_tvalid(axis_valid),
        .m_axis_tready(axis_ready),
        .capture_active(capture_active),
        .recovery_required(recovery_required),
        .overflow_sticky(overflow_sticky),
        .format_error_sticky(format_error_sticky),
        .frame_done_toggle(frame_done_toggle),
        .frame_error_toggle(frame_error_toggle),
        .good_frame_count(good_frames),
        .bad_frame_count(bad_frames),
        .last_error(last_error),
        .stream_ready(stream_ready),
        .sampled_vsync(sampled_vsync)
    );

    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *)
    reg [1:0] sensor_reset_sync;

    reg sensor_vsync_q;
    reg [31:0] sensor_frame_binary, sensor_frame_gray;

    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *)
    reg [31:0] sensor_gray_meta, sensor_gray_sync;

    always @(posedge cam_pclk or negedge axi_resetn)
        if (!axi_resetn)
            sensor_reset_sync <= 0;
        else
            sensor_reset_sync <= {sensor_reset_sync[0], 1'b1};

    always @(posedge cam_pclk or negedge sensor_reset_sync[1])
        if (!sensor_reset_sync[1]) begin
            sensor_vsync_q <= 1;
            sensor_frame_binary <= 0;
            sensor_frame_gray <= 0;
        end else begin
            sensor_vsync_q <= sampled_vsync;
            if (sensor_vsync_q && !sampled_vsync) begin
                sensor_frame_binary <= sensor_frame_binary + 1;
                sensor_frame_gray <=
                    ((sensor_frame_binary + 1) >> 1) ^
                    (sensor_frame_binary + 1);
            end
        end

    always @(posedge axi_clk or negedge axi_resetn)
        if (!axi_resetn) begin
            sensor_gray_meta <= 0;
            sensor_gray_sync <= 0;
        end else begin
            sensor_gray_meta <= sensor_frame_gray;
            sensor_gray_sync <= sensor_gray_meta;
        end

    function [31:0] gray_to_binary;
        input [31:0] value;
        integer k;
        begin
            gray_to_binary[31] = value[31];
            for (k = 30; k >= 0; k = k - 1)
                gray_to_binary[k] =
                    gray_to_binary[k+1] ^ value[k];
        end
    endfunction

    wire [31:0] sensor_frames = gray_to_binary(sensor_gray_sync);

    wire video_hsync, video_vsync, video_de;
    wire video_locked, video_underflow, video_overflow;

    reg underflow_seen;
    reg overflow_seen_axi;

    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *)
    reg [2:0] video_status_meta, video_status_sync;

    always @(posedge pixel_clk or negedge pixel_reset_sync[1]) begin
        if (!pixel_reset_sync[1])
            underflow_seen <= 1'b0;
        else if (video_underflow)
            underflow_seen <= 1'b1;
    end

    always @(posedge axi_clk or negedge axi_resetn) begin
        if (!axi_resetn) begin
            overflow_seen_axi <= 1'b0;
            video_status_meta <= 3'b000;
            video_status_sync <= 3'b000;
        end else begin
            if (video_overflow)
                overflow_seen_axi <= 1'b1;
            video_status_meta <= {
                overflow_seen_axi, underflow_seen, video_locked
            };
            video_status_sync <= video_status_meta;
        end
    end

    assign status = {
        bad_frames[15:0],
        last_error,
        sensor_status_sync[3],
        video_status_sync[2:0],
        capture_active,
        stream_ready,
        recovery_required,
        format_error_sticky,
        overflow_sticky,
        sensor_status_sync[2:0]
    };

    // Only processed, frame-matched scanout reaches the video output.
    video_system_wrapper u_system (
        .AI_tap_data(axis_rgb),
        .AI_tap_fire(axis_valid && axis_ready),
        .AI_tap_sof(axis_user),
        .AI_keys_n(pl_keys_n),
        .AI_tap_eol(axis_last),
        .AI_capture_run(control[0] && control[1] && sensor_status_sync[0] && !recovery_required),
        .AI_good_count(good_frames),
        .AI_bad_count(bad_frames),
        .AI_source_frame(sensor_frames),
        .AI_tensor_pending(),
        .axi_clk(axi_clk),
        .axi_resetn(axi_resetn),
        .captured_frames(good_frames),
        .sensor_frames(sensor_frames),
        .control(control),
        .status(status),
        .hdmi_locked(hdmi_locked),
        .pixel_clk(pixel_clk),
        .reset_req(sys_reset_sync[1]),
        .video_data(video_data),
        .video_de(video_de),
        .video_hsync(video_hsync),
        .video_vsync(video_vsync),
        .video_locked(video_locked),
        .video_underflow(video_underflow),
        .video_overflow(video_overflow),
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
        .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb)
    );

    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *)
    reg [1:0] display_enable_sync;

    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *)
    reg [1:0] video_locked_sync;

    reg display_video, video_vsync_q;
    wire display_allowed = display_enable_sync[1] && video_locked_sync[1];
    always @(posedge pixel_clk or negedge pixel_reset_sync[1]) begin
        if (!pixel_reset_sync[1]) begin
            display_enable_sync<=0; video_locked_sync<=0;
            display_video<=0; video_vsync_q<=0;
        end else begin
            display_enable_sync<={display_enable_sync[0],control[2]};
            video_locked_sync<={video_locked_sync[0],video_locked};
            video_vsync_q<=video_vsync;
            if(!display_allowed) display_video<=0;
            else if(video_vsync && !video_vsync_q) display_video<=1;
        end
    end
    wire [15:0] overlay_rgb=display_video ? video_data : 16'd0;
    wire selected_de=display_video && video_de;
    wire selected_vs=video_vsync;

    dvi_transmitter_top u_hdmi (
        .pixel_clk(pixel_clk),
        .pixel_clk_5x(pixel_clk_5x),
        .reset(!pixel_reset_sync[1]),
        .video_din(overlay_rgb),
        .video_hsync(video_hsync),
        .video_vsync(selected_vs),
        .video_de(selected_de),
        .tmds_clk_p(tmds_clk_p),
        .tmds_clk_n(tmds_clk_n),
        .tmds_data_p(tmds_data_p),
        .tmds_data_n(tmds_data_n)
    );

endmodule

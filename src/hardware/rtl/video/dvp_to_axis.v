`timescale 1ns / 1ps
// OV5640 RGB565 DVP -> packed RGB565 AXI4-Stream, one pixel per beat.
// VSYNC is active high; the falling edge starts the next sensor frame.
// HREF encloses exactly IMAGE_WIDTH*2 bytes, high RGB565 byte first.
//
// The sensor cannot accept backpressure. An input-format error or full FIFO
// latches recovery_required and stops camera writes. FIFO contents are NOT
// reset or withdrawn behind a stalled AXI beat. The controller must reset
// the capture consumer and assert stream_resetn low together. This flushes
// the partial frame; capture waits for FIFO reset completion and a fresh
// VSYNC falling edge. Diagnostic counters survive this stream-only reset.
// A good_frame_count increment proves sensor framing, not DDR completion.
module dvp_to_axis #(
    parameter integer IMAGE_WIDTH = 1280,
    parameter integer IMAGE_HEIGHT = 720,
    parameter integer FIFO_DEPTH = 8192
) (
    input  wire        aresetn,
    input  wire        stream_resetn,
    input  wire        capture_enable,
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_data,
    input  wire        axi_clk,
    output wire [15:0] m_axis_tdata,
    output wire [1:0]  m_axis_tkeep,
    output wire        m_axis_tuser,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    // All status outputs below are in axi_clk, suitable for AXI GPIO.
    output wire        capture_active,
    output wire        recovery_required,
    output wire        overflow_sticky,
    output wire        format_error_sticky,
    output wire        frame_done_toggle,
    output wire        frame_error_toggle,
    output wire [31:0] good_frame_count,
    output wire [31:0] bad_frame_count,
    output wire [3:0]  last_error,
    output wire        stream_ready,
    output wire        sampled_vsync
);
    localparam integer LINE_BYTES = IMAGE_WIDTH * 2;
    localparam integer BYTE_BITS = $clog2(LINE_BYTES + 2);
    localparam integer LINE_BITS = $clog2(IMAGE_HEIGHT + 2);
    localparam integer FIFO_COUNT_BITS = $clog2(FIFO_DEPTH) + 1;
    localparam [3:0] ERR_SHORT_LINE = 4'd1, ERR_ODD_BYTE = 4'd2,
                     ERR_LONG_LINE = 4'd3, ERR_EXTRA_LINE = 4'd4,
                     ERR_FRAME_HEIGHT = 4'd5, ERR_FIFO_FULL = 4'd6,
                     ERR_ENABLE_LOST = 4'd7, ERR_HREF_IN_VSYNC = 4'd8;

    // Source-synchronous input registers: preserve all DVP signals together.
    // No independent synchronizers may be inserted in this pixel bus.
    // Keep the complete sampler in fabric: the non-CCIO camera clock route
    // makes ILOGIC ZHOLD compensation exceed the half-cycle setup budget.
    // Sampling edge and latency are identical for data, HREF and VSYNC.
    (* IOB = "FALSE" *) reg [7:0] data_q;
    (* IOB = "FALSE" *) reg href_q, vsync_q;
    always @(posedge cam_pclk) begin
        data_q <= cam_data;
        href_q <= cam_href;
        vsync_q <= cam_vsync;
    end
    assign sampled_vsync = vsync_q;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] reset_cam_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] reset_axi_sync;
    wire cam_resetn = reset_cam_sync[1];
    wire axi_resetn = reset_axi_sync[1];
    always @(posedge cam_pclk or negedge aresetn) begin
        if (!aresetn) reset_cam_sync <= 2'b00;
        else reset_cam_sync <= {reset_cam_sync[0],1'b1};
    end
    always @(posedge axi_clk or negedge aresetn) begin
        if (!aresetn) reset_axi_sync <= 2'b00;
        else reset_axi_sync <= {reset_axi_sync[0],1'b1};
    end
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] enable_cam_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] stream_cam_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] stream_axi_sync;
    wire stream_arst_n = aresetn && stream_resetn;
    always @(posedge cam_pclk or negedge stream_arst_n) begin
        if (!stream_arst_n) stream_cam_sync <= 2'b00;
        else stream_cam_sync <= {stream_cam_sync[0], 1'b1};
    end
    always @(posedge axi_clk or negedge stream_arst_n) begin
        if (!stream_arst_n) stream_axi_sync <= 2'b00;
        else stream_axi_sync <= {stream_axi_sync[0], 1'b1};
    end
    always @(posedge cam_pclk or negedge cam_resetn) begin
        if (!cam_resetn) enable_cam_sync <= 2'b00;
        else enable_cam_sync <= {enable_cam_sync[0], capture_enable};
    end

    wire fifo_full, fifo_empty, wr_rst_busy, rd_rst_busy;
    wire [17:0] fifo_dout;
    reg frame_active_cam, fault_cam;
    reg overflow_cam, format_error_cam;
    reg done_toggle_cam, error_toggle_cam;
    reg [31:0] good_count_cam, bad_count_cam;
    reg [31:0] good_gray_cam, bad_gray_cam;
    reg [3:0] error_code_cam;
    reg vsync_prev, href_prev, byte_phase;
    reg [7:0] high_byte;
    reg [BYTE_BITS-1:0] byte_count;
    reg [LINE_BITS-1:0] completed_lines;
    wire vsync_rise = vsync_q && !vsync_prev;
    wire vsync_fall = !vsync_q && vsync_prev;
    wire href_fall = !href_q && href_prev;
    wire cam_stream_ready = cam_resetn && stream_cam_sync[1] && !wr_rst_busy;

    reg fault_event;
    reg [3:0] fault_code;
    always @(*) begin
        fault_event = 1'b0;
        fault_code = 4'd0;
        if (cam_stream_ready && !fault_cam && enable_cam_sync[1] &&
            vsync_fall && href_q) begin
            // This sampler requires the first HREF after the VSYNC edge.
            // Diagnose an ambiguous first byte rather than silently shifting it.
            fault_event = 1'b1; fault_code = ERR_HREF_IN_VSYNC;
        end else if (cam_stream_ready && frame_active_cam && !fault_cam) begin
            if (!enable_cam_sync[1]) begin
                fault_event = 1'b1; fault_code = ERR_ENABLE_LOST;
            end else if (href_q && vsync_q) begin
                fault_event = 1'b1; fault_code = ERR_HREF_IN_VSYNC;
            end else if (href_fall && byte_phase) begin
                fault_event = 1'b1; fault_code = ERR_ODD_BYTE;
            end else if (href_fall && byte_count != LINE_BYTES) begin
                fault_event = 1'b1; fault_code = ERR_SHORT_LINE;
            end else if (href_q && completed_lines >= IMAGE_HEIGHT) begin
                fault_event = 1'b1; fault_code = ERR_EXTRA_LINE;
            end else if (href_q && byte_count >= LINE_BYTES) begin
                fault_event = 1'b1; fault_code = ERR_LONG_LINE;
            end else if (href_q && byte_phase && fifo_full) begin
                fault_event = 1'b1; fault_code = ERR_FIFO_FULL;
            end else if (vsync_rise &&
                         !(completed_lines == IMAGE_HEIGHT ||
                           (href_fall && completed_lines == IMAGE_HEIGHT-1))) begin
                fault_event = 1'b1; fault_code = ERR_FRAME_HEIGHT;
            end
        end
    end

    wire [15:0] rgb565 = {high_byte, data_q};
    wire first_pixel = completed_lines == 0 && byte_count == 1;
    wire last_pixel = byte_count == LINE_BYTES-1;
    wire fifo_wr_en = cam_stream_ready && frame_active_cam &&
                      enable_cam_sync[1] && !fault_cam && !fault_event &&
                      href_q && !vsync_q && byte_phase && !fifo_full;
    wire [17:0] fifo_din = {first_pixel, last_pixel, rgb565};
    wire fifo_rd_en = m_axis_tvalid && m_axis_tready;
    assign m_axis_tdata = fifo_dout[15:0];
    assign m_axis_tlast = fifo_dout[16];
    assign m_axis_tuser = fifo_dout[17];
    assign m_axis_tkeep = 2'b11;
    assign m_axis_tvalid = axi_resetn && stream_axi_sync[1] && !rd_rst_busy && !fifo_empty;

    xpm_fifo_async #(
        .CDC_SYNC_STAGES(2), .DOUT_RESET_VALUE("0"), .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("block"), .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(FIFO_DEPTH), .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10), .PROG_FULL_THRESH(FIFO_DEPTH-10),
        .RD_DATA_COUNT_WIDTH(FIFO_COUNT_BITS), .READ_DATA_WIDTH(18),
        .READ_MODE("fwft"), .RELATED_CLOCKS(0), .SIM_ASSERT_CHK(1),
        .USE_ADV_FEATURES("0000"), .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(18), .WR_DATA_COUNT_WIDTH(FIFO_COUNT_BITS)
    ) u_pixel_fifo (
        .rst(!stream_cam_sync[1]), .wr_clk(cam_pclk), .rd_clk(axi_clk),
        .din(fifo_din), .wr_en(fifo_wr_en), .rd_en(fifo_rd_en),
        .dout(fifo_dout), .full(fifo_full), .empty(fifo_empty),
        .wr_rst_busy(wr_rst_busy), .rd_rst_busy(rd_rst_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .almost_empty(), .almost_full(), .data_valid(),
        .dbiterr(), .overflow(), .prog_empty(), .prog_full(),
        .rd_data_count(), .sbiterr(), .underflow(), .wr_ack(), .wr_data_count()
    );

    always @(posedge cam_pclk or negedge cam_resetn) begin
        if (!cam_resetn) begin
            frame_active_cam <= 1'b0; fault_cam <= 1'b0;
            overflow_cam <= 1'b0; format_error_cam <= 1'b0;
            done_toggle_cam <= 1'b0; error_toggle_cam <= 1'b0;
            good_count_cam <= 0; bad_count_cam <= 0;
            good_gray_cam <= 0; bad_gray_cam <= 0; error_code_cam <= 0;
            vsync_prev <= 1'b1; href_prev <= 1'b0; byte_phase <= 1'b0;
            high_byte <= 0; byte_count <= 0; completed_lines <= 0;
        end else begin
            vsync_prev <= vsync_q;
            href_prev <= href_q;
            if (!cam_stream_ready) begin
                // Recovery ACK comes from the controller's stream-only reset.
                frame_active_cam <= 1'b0;
                if (!stream_cam_sync[1]) fault_cam <= 1'b0;
                byte_phase <= 1'b0; byte_count <= 0; completed_lines <= 0;
            end else if (fault_event) begin
                frame_active_cam <= 1'b0; fault_cam <= 1'b1;
                error_code_cam <= fault_code;
                bad_count_cam <= bad_count_cam + 1'b1;
                bad_gray_cam <= ((bad_count_cam + 1'b1) >> 1) ^
                                (bad_count_cam + 1'b1);
                error_toggle_cam <= !error_toggle_cam;
                if (fault_code == ERR_FIFO_FULL) overflow_cam <= 1'b1;
                else format_error_cam <= 1'b1;
                byte_phase <= 1'b0;
            end else if (!fault_cam && enable_cam_sync[1]) begin
                if (vsync_rise && frame_active_cam) begin
                    good_count_cam <= good_count_cam + 1'b1;
                    good_gray_cam <= ((good_count_cam + 1'b1) >> 1) ^
                                     (good_count_cam + 1'b1);
                    done_toggle_cam <= !done_toggle_cam;
                    frame_active_cam <= 1'b0;
                    byte_phase <= 1'b0; byte_count <= 0;
                end else if (vsync_fall) begin
                    frame_active_cam <= 1'b1;
                    byte_phase <= 1'b0; byte_count <= 0; completed_lines <= 0;
                end else if (frame_active_cam) begin
                    if (href_q) begin
                        byte_count <= byte_count + 1'b1;
                        byte_phase <= !byte_phase;
                        if (!byte_phase) high_byte <= data_q;
                    end else if (href_fall) begin
                        completed_lines <= completed_lines + 1'b1;
                        byte_phase <= 1'b0; byte_count <= 0;
                    end
                end
            end else if (!frame_active_cam) begin
                byte_phase <= 1'b0; byte_count <= 0;
            end
        end
    end

    // Registered Gray counters make every CDC bus transition one bit only.
    // Apply the accompanying gray bus max-delay / bus-skew constraints.
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [31:0] good_gray_meta, good_gray_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [31:0] bad_gray_meta, bad_gray_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [5:0] status_meta, status_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [3:0] error_meta, error_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] ready_meta_sync;
    always @(posedge axi_clk or negedge axi_resetn) begin
        if (!axi_resetn) begin
            good_gray_meta <= 0; good_gray_sync <= 0;
            bad_gray_meta <= 0; bad_gray_sync <= 0;
            status_meta <= 0; status_sync <= 0;
            error_meta <= 0; error_sync <= 0; ready_meta_sync <= 0;
        end else begin
            good_gray_meta <= good_gray_cam; good_gray_sync <= good_gray_meta;
            bad_gray_meta <= bad_gray_cam; bad_gray_sync <= bad_gray_meta;
            status_meta <= {frame_active_cam, fault_cam, overflow_cam,
                            format_error_cam, done_toggle_cam, error_toggle_cam};
            status_sync <= status_meta;
            // Error code is held until the next error, longer than the flag CDC.
            error_meta <= error_code_cam; error_sync <= error_meta;
            ready_meta_sync <= {ready_meta_sync[0], cam_stream_ready};
        end
    end
    function [31:0] gray_to_bin;
        input [31:0] gray;
        integer n;
        begin
            gray_to_bin[31] = gray[31];
            for (n=30; n>=0; n=n-1)
                gray_to_bin[n] = gray_to_bin[n+1] ^ gray[n];
        end
    endfunction
    assign good_frame_count = gray_to_bin(good_gray_sync);
    assign bad_frame_count = gray_to_bin(bad_gray_sync);
    assign {capture_active, recovery_required, overflow_sticky,
            format_error_sticky, frame_done_toggle, frame_error_toggle} = status_sync;
    assign last_error = error_sync;
    assign stream_ready = stream_axi_sync[1] && !rd_rst_busy && ready_meta_sync[1];
endmodule

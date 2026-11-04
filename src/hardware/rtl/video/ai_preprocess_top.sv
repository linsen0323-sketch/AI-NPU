`timescale 1ns/1ps
// ABI4/CAM2 packed RGB565 frontend for PS-managed ResNet18/YOLOX inference.
// CONTROL[3] reads as one; removed tensor/automatic-engine CSRs read zero.
// Eight RGB565 slots have independent PS/display references; live display never waits for inference.
module ai_preprocess_top #(
    parameter integer IMAGE_WIDTH=1280, IMAGE_HEIGHT=720,
    parameter integer RESULT_MAX_AGE_CYCLES=500000000
) (
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 clk CLK", X_INTERFACE_PARAMETER="XIL_INTERFACENAME clk, ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET resetn, FREQ_HZ 100000000" *)
    input wire clk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 resetn RST", X_INTERFACE_PARAMETER="XIL_INTERFACENAME resetn, POLARITY ACTIVE_LOW" *)
    input wire resetn,
    input wire [1:0] pl_keys_n,
    input wire capture_run, tap_fire, tap_sof, tap_eol,
    input wire [15:0] tap_data,
    input wire [31:0] good_count, bad_count, source_frame,
    output wire tensor_pending,
    output wire processed_request,
    output wire frame_available, input wire frame_accept,
    output wire [31:0] frame_addr, frame_id, frame_generation,
    input wire scan_active_valid,
    input wire [31:0] scan_active_addr, scan_active_frame_id, scan_active_generation,
    input wire scan_retired_valid,
    input wire [31:0] scan_retired_addr, scan_retired_frame_id, scan_retired_generation,
    input wire [31:0] scan_fault, scan_displayed_frames,
    output reg scan_flush_request,
    input wire scan_flush_done,
    input wire processed_active_status,
    output reg display_result_valid, display_mode_detection,
    output wire [31:0] display_result_frame, display_result_generation,
    output wire [19:0] display_delay_bcd,
    output wire [2:0] display_model_id,
    output wire [19:0] display_inference_bcd,
    output wire [15:0] display_fps_bcd,
    output wire [1:0] display_status,
    output reg [2:0] display_class_id,
    output reg [6:0] display_score_pct,
    output reg [3:0] display_box_count,
    output reg [87:0] display_xmin, display_ymin, display_xmax, display_ymax,
    output reg [23:0] display_box_class,
    output reg [55:0] display_box_score,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWADDR", X_INTERFACE_PARAMETER="XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 16, READ_WRITE_MODE READ_WRITE" *) input wire [15:0] s_axi_awaddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input wire s_axi_awvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output wire s_axi_awready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WDATA" *) input wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *) input wire [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WVALID" *) input wire s_axi_wvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WREADY" *) output wire s_axi_wready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BRESP" *) output wire [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BVALID" *) output reg s_axi_bvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BREADY" *) input wire s_axi_bready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *) input wire [15:0] s_axi_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input wire s_axi_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output wire s_axi_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RDATA" *) output reg [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RRESP" *) output wire [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RVALID" *) output reg s_axi_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RREADY" *) input wire s_axi_rready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWADDR", X_INTERFACE_PARAMETER="XIL_INTERFACENAME M_AXI, PROTOCOL AXI4, DATA_WIDTH 64, ADDR_WIDTH 32, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1" *) output wire [31:0] m_axi_awaddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *) output wire [7:0] m_axi_awlen,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *) output wire [2:0] m_axi_awsize,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *) output wire [1:0] m_axi_awburst,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *) output wire m_axi_awlock,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *) output wire [3:0] m_axi_awcache,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *) output wire [2:0] m_axi_awprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *) output wire m_axi_awvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *) input wire m_axi_awready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WDATA" *) output wire [63:0] m_axi_wdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *) output wire [7:0] m_axi_wstrb,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WLAST" *) output wire m_axi_wlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WVALID" *) output wire m_axi_wvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WREADY" *) input wire m_axi_wready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI BRESP" *) input wire [1:0] m_axi_bresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI BVALID" *) input wire m_axi_bvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI BREADY" *) output wire m_axi_bready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *) output wire [31:0] m_axi_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *) output wire [7:0] m_axi_arlen,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *) output wire [2:0] m_axi_arsize,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *) output wire [1:0] m_axi_arburst,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *) output wire m_axi_arlock,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *) output wire [3:0] m_axi_arcache,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *) output wire [2:0] m_axi_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *) output wire m_axi_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *) input wire m_axi_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RDATA" *) input wire [63:0] m_axi_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RRESP" *) input wire [1:0] m_axi_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RLAST" *) input wire m_axi_rlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RVALID" *) input wire m_axi_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RREADY" *) output wire m_axi_rready
);
    localparam FREE=0, WRITING=1, READY=2, WAIT_RESULT=4, DISPLAY_READY=5, DISPLAY_HELD=6;
    reg enabled, processed_display, run_q;
    reg [31:0] generation;
    reg [63:0] cycles;
    reg [2:0] raw_state[0:7];
    reg [31:0] raw_frame[0:7], raw_generation[0:7];
    // One in-flight writer and one latest committed capture are sufficient:
    // raw_reserve can only select latest_capture_slot while that slot is READY.
    // Accepted PS leases retain their own independent 64-bit timestamp.
    reg [63:0] pending_capture_timestamp, latest_capture_timestamp;
    // Capture, PS and scanout hold independent references to immutable slots.
    reg [7:0] display_owned;
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] key_meta, key_sync;
    always @(posedge clk) begin
        if(!resetn) begin key_meta<=2'b11;key_sync<=2'b11;end
        else begin key_meta<=pl_keys_n;key_sync<=key_meta;end
    end


    reg live_display, matched_display, offered_once;
    reg [31:0] offered_frame, offered_generation;
    reg latest_capture_valid;
    reg [2:0] latest_capture_slot;
    reg [7:0] newer_than_offer;
    reg latest_valid, latest_detection;
    reg [2:0] latest_class;
    reg [6:0] latest_score;
    reg [3:0] latest_boxes;
    reg [87:0] latest_xmin,latest_ymin,latest_xmax,latest_ymax;
    reg [23:0] latest_box_class;
    reg [55:0] latest_box_score;
    reg [63:0] latest_timestamp;
    reg [63:0] latest_published;
    reg [31:0] result_hold_cycles, latest_frame, latest_generation;
    reg [2:0] latest_result_slot;
    reg [19:0] latest_delay_bcd, staged_delay_bcd;
    reg [2:0] latest_model_id, staged_model_id;
    reg [19:0] latest_inference_bcd, staged_inference_bcd;
    reg [15:0] latest_fps_bcd, staged_fps_bcd;
    reg [1:0] osd_status;
    reg [31:0] observed_scan_count, observed_frame, observed_generation;
    reg observed_valid;
    reg [31:0] unique_frames, repeated_frames;
    reg [2:0] snapshot_slot;
    reg [31:0] snapshot_count, snapshot_drops, fault, last_snapshot_error;
    reg lease_valid;
    reg [2:0] lease_raw;
    reg [31:0] lease_frame, lease_generation;
    reg [63:0] lease_timestamp;
    reg offer_valid;
    reg [2:0] offer_slot;
    reg [31:0] inference_count, rejected_results, display_results;
    reg [31:0] staged_frame, staged_generation;
    reg [2:0] staged_class;
    reg [6:0] staged_score;
    reg staged_detection;
    reg [3:0] staged_box_count;
    reg [87:0] staged_xmin, staged_ymin, staged_xmax, staged_ymax;
    reg [23:0] staged_box_class;
    reg [55:0] staged_box_score;
    reg [31:0] release_frame, release_generation, rejected_releases;
    reg aw_pending, w_pending;
    reg [15:0] aw_address;
    reg [31:0] w_data;
    reg [3:0] w_strobe;
    wire write_commit=aw_pending && w_pending && !s_axi_bvalid;
    wire claim=write_commit && aw_address[15:2]==14'h002 && w_strobe[0] && w_data[0] && !lease_valid;
    wire release_cmd=write_commit && aw_address[15:2]==14'h003 && w_strobe[0] && w_data[0];
    wire publish_cmd=write_commit && aw_address[15:2]==14'h048 && w_strobe[0] && w_data[0];
    // Purging never revokes an accepted PS lease or an active display reader.
    wire discard_pending=write_commit && aw_address[15:2]==14'h024 && w_strobe[0] && w_data[0];
    wire discard_display=write_commit && aw_address[15:2]==14'h024 && w_strobe[0] && w_data[1];
    reg raw_free, raw_ready;
    reg [2:0] raw_free_slot, raw_ready_slot;
    reg display_ready_exists;
    reg [2:0] display_ready_slot;
    wire raw_reserve=claim && raw_ready;
    wire offer_make=!offer_valid && (live_display || processed_display) && !scan_flush_request && !discard_display && display_ready_exists;
    wire sw_result_match=lease_valid && staged_frame==lease_frame && staged_generation==lease_generation;
    wire publish=publish_cmd && sw_result_match && osd_status==2'd1;
    wire result_fresh=latest_valid &&
        (result_hold_cycles==0 || cycles-latest_published<=result_hold_cycles);
    // Before the first result and while stopped/loading, matched mode falls
    // back to live capture. It must not starve preview or the status header.
    wire show_matched_result=matched_display && osd_status==2'd1 && result_fresh;
    assign processed_request=live_display ? capture_run : processed_display;
    assign tensor_pending=raw_ready; // Historical port name; packed RGB565 frame.
    assign frame_available=offer_valid && !scan_flush_request && !discard_display;
    assign frame_addr=32'h12000000+offer_slot*32'h400000;
    assign frame_id=raw_frame[offer_slot];
    assign frame_generation=raw_generation[offer_slot];

    // One snapshot writer completes in capture order. Its latest committed
    // slot is already the newest frame; no eight-way timestamp tournament
    // or capture/offer/reclaim combinational feedback is needed.
    always @(posedge clk) begin
        if (!resetn) begin
            latest_capture_valid<=0; latest_capture_slot<=0; newer_than_offer<=0;
        end else begin
            if (snapshot_done && snapshot_error==0) begin
                latest_capture_valid<=1; latest_capture_slot<=snapshot_slot;
            end
            for (integer j=0;j<8;j=j+1)
                newer_than_offer[j]<=!offered_once || raw_generation[j]!=offered_generation || raw_frame[j]!=offered_frame;
        end
    end
    always @* begin
        raw_free=0; raw_free_slot=0;
        for (integer j=0;j<8;j=j+1)
            if (raw_state[j]==FREE && !display_owned[j]) begin raw_free=1; raw_free_slot=j; end
        raw_ready_slot=latest_capture_slot;
        raw_ready=latest_capture_valid && raw_state[latest_capture_slot]==READY;
        display_ready_slot=show_matched_result ? latest_result_slot : latest_capture_slot;
        display_ready_exists=show_matched_result ?
            (latest_valid && raw_state[latest_result_slot]==DISPLAY_READY &&
             !display_owned[latest_result_slot] && newer_than_offer[latest_result_slot]) :
            (latest_capture_valid &&
            (raw_state[latest_capture_slot]==READY || raw_state[latest_capture_slot]==WAIT_RESULT) &&
            !display_owned[latest_capture_slot] && newer_than_offer[latest_capture_slot]);
    end
    // The compositor samples this complete result atomically at video SOF.
    // Hold from publication; source identity and inference delay remain explicit.
    // Matched view draws only on the original inference image.
    assign display_result_frame=latest_frame;
    assign display_result_generation=latest_generation;
    assign display_delay_bcd=latest_delay_bcd;
    assign display_model_id=latest_valid && osd_status==2'd1 ? latest_model_id : staged_model_id;
    assign display_inference_bcd=latest_valid && osd_status==2'd1 ? latest_inference_bcd : 20'd0;
    assign display_fps_bcd=latest_valid && osd_status==2'd1 ? latest_fps_bcd : 16'd0;
    assign display_status=osd_status;
    always @* begin
        // Geometry is forbidden in independent preview. The slot address is
        // checked as well as frame/generation, including after model changes.
        display_result_valid=scan_active_valid && show_matched_result &&
            scan_active_addr==32'h12000000+latest_result_slot*32'h400000 &&
            scan_active_frame_id==latest_frame && scan_active_generation==latest_generation;
        display_mode_detection=latest_detection;
        display_class_id=latest_class;
        // A completed classifier summary may outlive geometry's frame-age
        // window, but an invalidated result must never revive a stale score.
        display_score_pct=latest_valid ? latest_score : 7'd127;
        display_box_count=latest_boxes;
        display_xmin=latest_xmin; display_ymin=latest_ymin;
        display_xmax=latest_xmax; display_ymax=latest_ymax;
        display_box_class=latest_box_class; display_box_score=latest_box_score;
    end
    wire snapshot_idle, snapshot_done;
    wire [3:0] snapshot_error;
    wire [2:0] snapshot_target=raw_free_slot;
    wire snapshot_start=(enabled || live_display) && !discard_pending && fault==0 && capture_run &&
        raw_free && snapshot_idle && tap_fire && tap_sof;
    wire wr_req, wr_accept, wr_valid, wr_ready, wr_done, wr_error;
    wire [31:0] wr_addr;
    wire [63:0] wr_data;
    ai_dma64 u_dma (.*);
    ai_snapshot #(.IMAGE_WIDTH(IMAGE_WIDTH),.IMAGE_HEIGHT(IMAGE_HEIGHT)) u_snapshot (
        .clk(clk), .resetn(resetn), .capture_run(capture_run),
        .tap_fire(tap_fire), .tap_sof(tap_sof), .tap_eol(tap_eol), .tap_data(tap_data),
        .good_count(good_count), .bad_count(bad_count), .idle(snapshot_idle),
        .start(snapshot_start), .base_addr(32'h12000000+snapshot_target*32'h400000),
        .done(snapshot_done), .error(snapshot_error),
        .wr_req(wr_req), .wr_accept(wr_accept), .wr_addr(wr_addr),
        .wr_data(wr_data), .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_done(wr_done), .wr_error(wr_error)
    );
    assign s_axi_awready=!aw_pending && !s_axi_bvalid;
    assign s_axi_wready=!w_pending && !s_axi_bvalid;
    assign s_axi_bresp=0;
    assign s_axi_arready=!s_axi_rvalid;
    assign s_axi_rresp=0;
    integer i;
    always @(posedge clk) begin
        if (!resetn) begin
            enabled<=0; processed_display<=0; live_display<=0; matched_display<=1;
            result_hold_cycles<=RESULT_MAX_AGE_CYCLES; latest_published<=0;
            latest_frame<=0; latest_generation<=0; latest_result_slot<=0;
            latest_delay_bcd<=0; staged_delay_bcd<=0;
            latest_model_id<=0; staged_model_id<=0; osd_status<=0;
            latest_inference_bcd<=0; staged_inference_bcd<=0;
            latest_fps_bcd<=0; staged_fps_bcd<=0;
            display_owned<=0; offered_once<=0; offered_frame<=0; offered_generation<=0;
            latest_valid<=0; latest_detection<=0; latest_class<=7; latest_score<=127; latest_boxes<=0;
            latest_xmin<=0; latest_ymin<=0; latest_xmax<=0; latest_ymax<=0;
            latest_box_class<=0; latest_box_score<=0; latest_timestamp<=0;
            observed_scan_count<=0; observed_frame<=0; observed_generation<=0; observed_valid<=0;
            unique_frames<=0; repeated_frames<=0; run_q<=0; generation<=0; cycles<=0;
            snapshot_slot<=0; snapshot_count<=0; snapshot_drops<=0;
            pending_capture_timestamp<=0; latest_capture_timestamp<=0;
            fault<=0; last_snapshot_error<=0;
            lease_valid<=0; lease_raw<=0; lease_frame<=0; lease_generation<=0; lease_timestamp<=0;
            offer_valid<=0; offer_slot<=0; scan_flush_request<=0;
            inference_count<=0; rejected_results<=0; display_results<=0;
            staged_frame<=0; staged_generation<=0; staged_class<=7; staged_score<=127; staged_detection<=0;
            staged_box_count<=0; staged_xmin<=0; staged_ymin<=0; staged_xmax<=0; staged_ymax<=0;
            staged_box_class<=0; staged_box_score<=0;
            release_frame<=0; release_generation<=0; rejected_releases<=0;
            aw_pending<=0; w_pending<=0; aw_address<=0; w_data<=0; w_strobe<=0;
            s_axi_bvalid<=0; s_axi_rvalid<=0; s_axi_rdata<=0;
            for (i=0;i<8;i=i+1) begin
                raw_state[i]<=FREE; raw_frame[i]<=0; raw_generation[i]<=0;

            end
        end else begin
            cycles<=cycles+1'b1; run_q<=capture_run;
            if (scan_displayed_frames!=observed_scan_count) begin
                observed_scan_count<=scan_displayed_frames;
                observed_valid<=1; observed_frame<=scan_active_frame_id; observed_generation<=scan_active_generation;
                if (!observed_valid || scan_active_frame_id!=observed_frame || scan_active_generation!=observed_generation)
                    unique_frames<=unique_frames+1'b1;
                else repeated_frames<=repeated_frames+1'b1;
            end
            if (capture_run && !run_q) generation<=generation+1'b1;
            if ((enabled || live_display) && tap_fire && tap_sof && !snapshot_start) snapshot_drops<=snapshot_drops+1'b1;
            if (snapshot_start) begin
                snapshot_slot<=snapshot_target; raw_state[snapshot_target]<=WRITING;
                raw_frame[snapshot_target]<=source_frame; raw_generation[snapshot_target]<=generation;
                pending_capture_timestamp<=cycles;
            end
            // Reclaim only unleased, unoffered raw images. WAIT_RESULT and
            // DISPLAY_HELD retain their ownership until explicit retirement.
            for (integer j=0;j<8;j=j+1)
                if (raw_state[j]==READY && !display_owned[j] && !(snapshot_start && snapshot_target==j) && (!raw_ready || j!=raw_ready_slot) &&
                    !(raw_reserve && raw_ready_slot==j) && !(offer_make && display_ready_slot==j)) raw_state[j]<=FREE;
            if (snapshot_done) begin
                last_snapshot_error<=snapshot_error;
                if (snapshot_error!=0) raw_state[snapshot_slot]<=FREE;
                else begin
                    raw_state[snapshot_slot]<=READY; snapshot_count<=snapshot_count+1'b1;
                    // NBA semantics retain the old pending timestamp if a new
                    // start ever coincides with this completion.
                    latest_capture_timestamp<=pending_capture_timestamp;
                end
            end
            if ((snapshot_done && snapshot_error==3) || scan_fault!=0)
                fault<=fault | ((snapshot_done && snapshot_error==3) ? 32'd1 : 0) | (scan_fault!=0 ? 32'd4 : 0);
            if (s_axi_awvalid && s_axi_awready) begin aw_pending<=1; aw_address<=s_axi_awaddr; end
            if (s_axi_wvalid && s_axi_wready) begin w_pending<=1; w_data<=s_axi_wdata; w_strobe<=s_axi_wstrb; end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
            if (write_commit) begin
                aw_pending<=0; w_pending<=0; s_axi_bvalid<=1;
                case (aw_address[15:2])
                    'h001: if (w_strobe[0]) begin enabled<=w_data[0]; processed_display<=w_data[2]; live_display<=w_data[4]; matched_display<=w_data[5]; end
                    'h02a: for (integer b=0;b<4;b=b+1) if (w_strobe[b]) result_hold_cycles[b*8+:8]<=w_data[b*8+:8];
                    'h004: for (integer b=0;b<4;b=b+1) if (w_strobe[b]) release_frame[b*8+:8]<=w_data[b*8+:8];
                    'h005: for (integer b=0;b<4;b=b+1) if (w_strobe[b]) release_generation[b*8+:8]<=w_data[b*8+:8];
                    'h060: if (&w_strobe) staged_frame<=w_data;
                    'h061: if (&w_strobe) staged_generation<=w_data;
                    'h062: if (&w_strobe) begin staged_class<=w_data[2:0]; staged_score<=w_data[14:8]; end
                    'h063: if (w_strobe[0]) begin staged_box_count<=w_data[3:0]; staged_detection<=w_data[4]; end
                    'h064: if (&w_strobe) staged_delay_bcd<=w_data[19:0];
                    'h065: if (&w_strobe) staged_model_id<=w_data[2:0];
                    'h066: if (&w_strobe) staged_inference_bcd<=w_data[19:0];
                    'h067: if (&w_strobe) staged_fps_bcd<=w_data[15:0];
                    'h068: if (w_strobe[0]) begin
                        osd_status<=w_data[1:0];
                        // Retire stale inference metadata at STOP/LOAD/ERR.
                        // Display ownership still fences any active DDR reader.
                        if (w_data[1:0]!=2'd1) begin
                            latest_valid<=0;
                            if (latest_valid && raw_state[latest_result_slot]==DISPLAY_READY)
                                raw_state[latest_result_slot]<=FREE;
                        end
                    end
                    default: ;
                endcase
                if (aw_address>=16'h0200 && aw_address<16'h0280 && &w_strobe) begin
                    // Unroll each address into fixed destination slices so
                    // the write path needs no variable-position vector shifter.
                    for (integer b=0;b<8;b=b+1) if (aw_address[6:4]==b) begin
                        case (aw_address[3:2])
                            0: begin staged_xmin[b*11+:11]<=w_data[10:0]; staged_ymin[b*11+:11]<=w_data[26:16]; end
                            1: begin staged_xmax[b*11+:11]<=w_data[10:0]; staged_ymax[b*11+:11]<=w_data[26:16]; end
                            2: begin staged_box_class[b*3+:3]<=w_data[2:0]; staged_box_score[b*7+:7]<=w_data[14:8]; end
                            default: ;
                        endcase
                    end
                end
            end
            if (write_commit && aw_address[15:2]==14'h024 && w_strobe[0] && w_data[4]) begin
                latest_valid<=0;
                if (latest_valid && raw_state[latest_result_slot]==DISPLAY_READY) raw_state[latest_result_slot]<=FREE;
            end
            if (discard_pending)
                for (integer j=0;j<8;j=j+1) if (raw_state[j]==READY) raw_state[j]<=FREE;
            if (discard_display) begin
                processed_display<=0; scan_flush_request<=1;
                latest_valid<=0; offered_once<=0;
                if (offer_valid) begin display_owned[offer_slot]<=0; offer_valid<=0; end
            end
            if (discard_display || scan_flush_request)
                for (integer j=0;j<8;j=j+1) if (raw_state[j]==DISPLAY_READY) raw_state[j]<=FREE;
            if (scan_flush_request && scan_flush_done && !discard_display) scan_flush_request<=0;
            if (raw_reserve) begin
                lease_valid<=1; lease_raw<=raw_ready_slot;
                lease_frame<=raw_frame[raw_ready_slot]; lease_generation<=raw_generation[raw_ready_slot];
                // raw_ready_slot is exactly latest_capture_slot, and raw_ready
                // requires that latest committed slot to remain READY.
                lease_timestamp<=latest_capture_timestamp; raw_state[raw_ready_slot]<=WAIT_RESULT;
            end
            if (release_cmd) begin
                if (lease_valid && release_frame==lease_frame && release_generation==lease_generation) begin
                    lease_valid<=0; raw_state[lease_raw]<=display_owned[lease_raw] ? READY : FREE;
                end else rejected_releases<=rejected_releases+1'b1;
            end
            if (publish_cmd && (!sw_result_match || osd_status!=2'd1)) rejected_results<=rejected_results+1'b1;
            if (publish) begin
                // Pin one immutable original image even in live mode. Old
                // scanout references still fence reuse after replacement.
                if (latest_valid && raw_state[latest_result_slot]==DISPLAY_READY) raw_state[latest_result_slot]<=FREE;
                raw_state[lease_raw]<=DISPLAY_READY; lease_valid<=0;
                latest_result_slot<=lease_raw; latest_frame<=lease_frame; latest_generation<=lease_generation;
                latest_valid<=1; latest_timestamp<=lease_timestamp; latest_published<=cycles;
                latest_delay_bcd<=staged_delay_bcd;
                latest_model_id<=staged_model_id;
                latest_inference_bcd<=staged_inference_bcd;
                latest_fps_bcd<=staged_fps_bcd;
                latest_class<=staged_class; latest_score<=staged_score; latest_detection<=staged_detection;
                latest_boxes<=staged_box_count>8 ? 4'd8 : staged_box_count;
                latest_xmin<=staged_xmin; latest_ymin<=staged_ymin;
                latest_xmax<=staged_xmax; latest_ymax<=staged_ymax;
                latest_box_class<=staged_box_class; latest_box_score<=staged_box_score;
                inference_count<=inference_count+1'b1;
            end
            if (offer_make) begin
                offer_valid<=1; offer_slot<=display_ready_slot; display_owned[display_ready_slot]<=1;
                offered_once<=1; offered_frame<=raw_frame[display_ready_slot];
                offered_generation<=raw_generation[display_ready_slot];
            end
            if (frame_accept && frame_available && offer_valid) begin offer_valid<=0; display_results<=display_results+1'b1; end
            if (scan_retired_valid)
                for (integer j=0;j<8;j=j+1)
                    if (display_owned[j] && scan_retired_addr==32'h12000000+j*32'h400000 &&
                        scan_retired_frame_id==raw_frame[j] && scan_retired_generation==raw_generation[j]) display_owned[j]<=0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid<=1;
                case (s_axi_araddr[15:2])
                    // Retired PS-rendered UI/preview CSRs read zero through
                    // default. KEY1 stays independent of that removed ABI.
                    'h0d0: s_axi_rdata<=32'h4b455931; // KEY1, raw synchronized active-low inputs.
                    'h0d1: s_axi_rdata<={30'd0,key_sync};
                    'h000: s_axi_rdata<=32'h50525031;
                    'h001: s_axi_rdata<={26'd0,matched_display,live_display,1'b1,processed_display,1'b0,enabled};
                    'h006: s_axi_rdata<={24'd0,1'b0,processed_active_status,fault!=0,lease_valid,tensor_pending,1'b0,!snapshot_idle,enabled};
                    'h007: s_axi_rdata<=fault;
                    'h008: s_axi_rdata<=snapshot_count;
                    'h009: s_axi_rdata<=snapshot_drops;
                    'h00c: s_axi_rdata<=last_snapshot_error;
                    'h00e: s_axi_rdata<=rejected_releases;
                    'h010: s_axi_rdata<={31'd0,lease_valid};
                    'h011: s_axi_rdata<=lease_valid ? 32'h12000000+lease_raw*32'h400000 : 0;
                    'h012: s_axi_rdata<=lease_valid ? lease_frame : 0;
                    'h013: s_axi_rdata<=lease_valid ? lease_generation : 0;
                    'h014: s_axi_rdata<=lease_valid ? lease_timestamp[31:0] : 0;
                    'h015: s_axi_rdata<=lease_valid ? lease_timestamp[63:32] : 0;
                    'h016: s_axi_rdata<=IMAGE_WIDTH*IMAGE_HEIGHT*2;
                    'h017: s_axi_rdata<=8;
                    'h018: s_axi_rdata<=lease_valid ? 32'h12000000+lease_raw*32'h400000 : 0;
                    'h019: s_axi_rdata<=inference_count;
                    'h01b: s_axi_rdata<=rejected_results;
                    'h01c: s_axi_rdata<=display_results;
                    'h020: s_axi_rdata<=scan_displayed_frames;
                    'h021: s_axi_rdata<=scan_fault;
                    'h022: s_axi_rdata<=32'h43414D32;
                    'h025: s_axi_rdata<=32'h4C495631; // LIV1, independent display references.
                    'h026: s_axi_rdata<=unique_frames;
                    'h027: s_axi_rdata<=repeated_frames;
                    'h028: s_axi_rdata<=cycles[31:0]-latest_timestamp[31:0];
                    'h029: s_axi_rdata<={31'd0,display_result_valid};
                    'h02a: s_axi_rdata<=result_hold_cycles;
                    'h02b: s_axi_rdata<=32'h4f564c33; // OVL3 BCD metrics/status + strict matched geometry.
                    'h02c: s_axi_rdata<=cycles[31:0];
                    'h02d: s_axi_rdata<=cycles[63:32];
                    'h02e: s_axi_rdata<=cycles[31:0]-latest_published[31:0];
                    'h02f: s_axi_rdata<=latest_frame;
                    'h030: s_axi_rdata<=latest_generation;
                    'h031: s_axi_rdata<={28'd0,latest_boxes};
                    'h032: s_axi_rdata<={25'd0,latest_score};
                    'h064: s_axi_rdata<={12'd0,staged_delay_bcd};
                    'h065: s_axi_rdata<={29'd0,staged_model_id};
                    'h066: s_axi_rdata<={12'd0,staged_inference_bcd};
                    'h067: s_axi_rdata<={16'd0,staged_fps_bcd};
                    'h068: s_axi_rdata<={30'd0,osd_status};
                    'h069: s_axi_rdata<=32'h26110104; // Fixed PL build contract, 2026-11-01 revision 04.
                    // [23:16]=8 slots, [15:8]=3 models; bit0=OVL3 BCD metadata,
                    // bit1=immediate status, bit2=strict matched-only geometry.
                    'h06a: s_axi_rdata<=32'h00080307;
                    'h023: s_axi_rdata<={24'd0,scan_flush_request,1'b0,raw_ready,2'b00,lease_valid,1'b0,!snapshot_idle};
                    default: s_axi_rdata<=0; // Retired preprocess/automatic-path CSRs.
                endcase
            end
        end
    end
endmodule

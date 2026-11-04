`timescale 1ns/1ps
// Read immutable packed RGB565 frames and serialize one RGB565 pixel/beat.
// DDR stores little-endian RGB565 words, four pixels/AXI beat. The descriptor MUST retain ownership
// of its source slot until retired_valid. A descriptor is accepted into a
// one-entry mailbox and selected only between complete AXIS video frames.
//
// enable is a graceful run request, NOT an AXI reset. Deasserting it finishes
// the current frame and retains the displayed slot. Only global resetn may
// reset an outstanding AXI transaction. An AXI fault is sticky until resetn;
// a fault can truncate a frame already streamed, so downstream video recovery
// is required before resuming. No source slot is retired on a fault.
module ai_frame_scanout #(
    parameter integer IMAGE_WIDTH = 1280,
    parameter integer IMAGE_HEIGHT = 720,
    parameter integer FIFO_WORDS = 1024,
    parameter integer PREFILL_WORDS = 64
) (
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 clk CLK", X_INTERFACE_PARAMETER="XIL_INTERFACENAME clk, ASSOCIATED_BUSIF M_AXI:M_AXIS_VIDEO, ASSOCIATED_RESET resetn, FREQ_HZ 100000000" *)
    input wire clk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 resetn RST", X_INTERFACE_PARAMETER="XIL_INTERFACENAME resetn, POLARITY ACTIVE_LOW" *)
    input wire resetn,
    input wire enable,
    // Explicit model-switch fence. Finish the current frame and every AXI
    // read, then retire queued/active descriptors before acknowledging.
    // A fault deliberately retains ownership and prevents acknowledgement.
    input wire flush_request,
    output wire flush_done,

    // frame_accept is the actual acceptance pulse, not a separate READY.
    // Input descriptor and frame_available stay stable until that pulse.
    input wire frame_available,
    output wire frame_accept,
    input wire [31:0] frame_addr, frame_id, frame_generation,

    // Metadata is stable through the entire corresponding output AXIS frame.
    output reg active_valid,
    output reg [31:0] active_addr, active_frame_id, active_generation,
    output reg frame_selected, // New descriptor selected; active_* already updated.
    output reg display_started, // SOF handshake; asserted again on every repeat.
    output reg retired_valid,
    output reg [31:0] retired_addr, retired_frame_id, retired_generation,
    output wire quiescent,     // No active AXIS frame/read; active slot still owned.
    // fault[0]: unaligned descriptor; [1]: RRESP; [2]: malformed RLAST;
    // [3]: internal frame-completion fence failed.
    output reg [31:0] fault,
    output reg [31:0] displayed_frames, completed_frames,
    output reg [31:0] read_bursts, starvation_cycles,

    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS_VIDEO TDATA", X_INTERFACE_PARAMETER="XIL_INTERFACENAME M_AXIS_VIDEO, TDATA_NUM_BYTES 2, TUSER_WIDTH 1, HAS_TLAST 1, HAS_TKEEP 0, HAS_TSTRB 0" *)
    output wire [15:0] m_axis_tdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS_VIDEO TVALID" *)
    output wire m_axis_tvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS_VIDEO TREADY" *)
    input wire m_axis_tready,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS_VIDEO TUSER" *)
    output wire m_axis_tuser,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS_VIDEO TLAST" *)
    output wire m_axis_tlast,

    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARADDR", X_INTERFACE_PARAMETER="XIL_INTERFACENAME M_AXI, PROTOCOL AXI4, DATA_WIDTH 64, ADDR_WIDTH 32, READ_WRITE_MODE READ_ONLY, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 1" *)
    output reg [31:0] m_axi_araddr,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *) output wire [7:0] m_axi_arlen,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *) output wire [2:0] m_axi_arsize,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *) output wire [1:0] m_axi_arburst,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *) output wire m_axi_arlock,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *) output wire [3:0] m_axi_arcache,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *) output wire [2:0] m_axi_arprot,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *) output reg m_axi_arvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *) input wire m_axi_arready,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RDATA" *) input wire [63:0] m_axi_rdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RRESP" *) input wire [1:0] m_axi_rresp,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RLAST" *) input wire m_axi_rlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RVALID" *) input wire m_axi_rvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RREADY" *) output wire m_axi_rready
);
    localparam integer BURST_WORDS = 16;
    localparam integer FRAME_WORDS = IMAGE_WIDTH * IMAGE_HEIGHT / 4;
    localparam integer COUNT_WIDTH = $clog2(FIFO_WORDS) + 1;

    // FIFO credit is reserved for a whole burst before asserting ARVALID.
    // One outstanding burst plus >=32 words of storage prevents R backpressure
    // from depending on pixel-side service. Default storage is 8 KiB / 4096 px.
    wire [63:0] fifo_data;
    wire fifo_empty, fifo_full, fifo_wr_busy, fifo_rd_busy;
    reg [COUNT_WIDTH-1:0] fifo_used;
    wire fifo_push, fifo_pop;
    reg pending_valid;
    reg [31:0] pending_addr, pending_frame_id, pending_generation;
    reg frame_running, streaming;
    reg [1:0] pixel_lane;
    reg [15:0] x, y;
    reg [31:0] next_address, words_issued, words_received;
    reg read_busy, address_sent;
    reg [4:0] read_beat;

    assign m_axi_arlen = 8'd15;
    assign m_axi_arsize = 3'd3;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock = 1'b0;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot = 3'b000;
    assign frame_accept = frame_available && resetn && enable && !flush_request && !pending_valid && fault == 0;
    assign quiescent = !frame_running && !read_busy && !m_axi_arvalid &&
                       fifo_empty && fifo_used == 0;
    assign flush_done = flush_request && fault == 0 && quiescent &&
                        !fifo_wr_busy && !fifo_rd_busy && !pending_valid && !active_valid;

    wire pixel_fire = m_axis_tvalid && m_axis_tready;
    wire end_of_frame = pixel_fire && x == IMAGE_WIDTH-1 && y == IMAGE_HEIGHT-1;
    wire completion_fence = !read_busy && !m_axi_arvalid &&
                            words_issued == FRAME_WORDS && words_received == FRAME_WORDS &&
                            fifo_used == 1 && pixel_lane == 3;
    wire response_fire = m_axi_rvalid && m_axi_rready;
    wire response_good = m_axi_rresp == 2'b00 && read_beat < BURST_WORDS &&
                         m_axi_rlast == (read_beat == BURST_WORDS-1);
    assign m_axi_rready = read_busy && address_sent &&
                         ((fault != 0 || read_beat >= BURST_WORDS) || !fifo_full);
    assign fifo_push = response_fire && fault == 0 && response_good;

    // FWFT data and all sidebands remain unchanged during AXIS backpressure.
    // A word is released only after all four pixels have been accepted.
    assign m_axis_tdata = fifo_data[pixel_lane*16 +: 16];
    assign m_axis_tvalid = frame_running && streaming && !fifo_empty && fifo_used != 0;
    assign m_axis_tuser = x == 0 && y == 0;
    assign m_axis_tlast = x == IMAGE_WIDTH-1;
    assign fifo_pop = pixel_fire && pixel_lane == 3;

    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(FIFO_WORDS),
        .WRITE_DATA_WIDTH(64), .READ_DATA_WIDTH(64), .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0), .WR_DATA_COUNT_WIDTH(COUNT_WIDTH),
        .RD_DATA_COUNT_WIDTH(COUNT_WIDTH), .USE_ADV_FEATURES("0707"),
        .PROG_FULL_THRESH(FIFO_WORDS-32), .PROG_EMPTY_THRESH(16),
        .DOUT_RESET_VALUE("0"), .ECC_MODE("no_ecc"), .FULL_RESET_VALUE(0),
        .WAKEUP_TIME(0)
    ) u_pixels (
        .wr_clk(clk), .rst(!resetn), .din(m_axi_rdata), .wr_en(fifo_push),
        .rd_en(fifo_pop), .dout(fifo_data), .full(fifo_full), .empty(fifo_empty),
        .wr_data_count(), .rd_data_count(),
        .wr_rst_busy(fifo_wr_busy), .rd_rst_busy(fifo_rd_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .almost_empty(), .almost_full(), .data_valid(), .dbiterr(), .sbiterr(),
        .overflow(), .underflow(), .prog_empty(), .prog_full(), .wr_ack()
    );

    always @(posedge clk) begin
        if (!resetn) begin
            pending_valid <= 0;
            pending_addr <= 0; pending_frame_id <= 0; pending_generation <= 0;
            active_valid <= 0;
            active_addr <= 0; active_frame_id <= 0; active_generation <= 0;
            frame_selected <= 0;
            retired_valid <= 0;
            retired_addr <= 0; retired_frame_id <= 0; retired_generation <= 0;
            display_started <= 0;
            frame_running <= 0; streaming <= 0; pixel_lane <= 0;
            x <= 0; y <= 0; next_address <= 0; words_issued <= 0; words_received <= 0;
            read_busy <= 0; address_sent <= 0; read_beat <= 0;
            m_axi_arvalid <= 0; m_axi_araddr <= 0;
            fault <= 0;
            displayed_frames <= 0; completed_frames <= 0;
            read_bursts <= 0; starvation_cycles <= 0;
            fifo_used <= 0;
        end else begin
            retired_valid <= 0;
            display_started <= 0;
            frame_selected <= 0;
            // Exact push/pop accounting avoids depending on implementation-
            // specific latency of XPM's optional data-count output.
            case ({fifo_push, fifo_pop})
                2'b10: fifo_used <= fifo_used + 1'b1;
                2'b01: fifo_used <= fifo_used - 1'b1;
                default: ;
            endcase
            if (fifo_push) words_received <= words_received + 1'b1;
            if (frame_accept) begin
                pending_valid <= 1;
                pending_addr <= frame_addr;
                pending_frame_id <= frame_id;
                pending_generation <= frame_generation;
                if (frame_addr[6:0] != 0) fault[0] <= 1; // Descriptor alignment.
            end

            // Pending has not been read, while active is released only after
            // the complete pixel/AXI fence. The one retirement port reports
            // one descriptor per clock, so the frontend never loses a lease.
            if (flush_request && fault == 0 && quiescent && !fifo_wr_busy && !fifo_rd_busy) begin
                if (pending_valid) begin
                    retired_valid <= 1;
                    retired_addr <= pending_addr;
                    retired_frame_id <= pending_frame_id;
                    retired_generation <= pending_generation;
                    pending_valid <= 0;
                end else if (active_valid) begin
                    retired_valid <= 1;
                    retired_addr <= active_addr;
                    retired_frame_id <= active_frame_id;
                    retired_generation <= active_generation;
                    active_valid <= 0;
                end
            end

            // Every transition starts with an empty pixel FIFO and no read in
            // flight. Thus retirement cannot free storage still read by AXI.
            // It is safe for VideoOut's downstream FIFO to retain old pixels:
            // they no longer depend on source DDR and already carry their OSD.
            if (!frame_running && !read_busy && !m_axi_arvalid && fifo_empty && fifo_used == 0 &&
                !fifo_wr_busy && !fifo_rd_busy && enable && !flush_request && fault == 0 &&
                (!active_valid || words_received == FRAME_WORDS) &&
                (pending_valid || active_valid)) begin
                frame_running <= 1;
                streaming <= 0; pixel_lane <= 0; x <= 0; y <= 0;
                words_issued <= 0; words_received <= 0;
                if (pending_valid) begin
                    frame_selected <= 1;
                    if (active_valid &&
                        (active_addr != pending_addr || active_frame_id != pending_frame_id ||
                         active_generation != pending_generation)) begin
                        retired_valid <= 1;
                        retired_addr <= active_addr;
                        retired_frame_id <= active_frame_id;
                        retired_generation <= active_generation;
                    end
                    active_valid <= 1;
                    active_addr <= pending_addr;
                    active_frame_id <= pending_frame_id;
                    active_generation <= pending_generation;
                    next_address <= pending_addr;
                    pending_valid <= 0;
                end else next_address <= active_addr;
            end

            if (frame_running && !read_busy && !m_axi_arvalid && fault == 0 &&
                !fifo_wr_busy && !fifo_rd_busy && words_issued < FRAME_WORDS &&
                fifo_used <= FIFO_WORDS-BURST_WORDS) begin
                m_axi_araddr <= next_address;
                m_axi_arvalid <= 1;
                read_busy <= 1;
                address_sent <= 0;
                read_beat <= 0;
                next_address <= next_address + 32'd128;
                words_issued <= words_issued + BURST_WORDS;
                read_bursts <= read_bursts + 1'b1;
            end
            if (m_axi_arvalid && m_axi_arready) begin
                m_axi_arvalid <= 0;
                address_sent <= 1;
            end
            if (response_fire) begin
                if (m_axi_rresp != 0) fault[1] <= 1;
                if (m_axi_rlast != (read_beat == BURST_WORDS-1)) fault[2] <= 1;
                if (read_beat < BURST_WORDS) read_beat <= read_beat + 1'b1;
                // Even an invalid burst is drained through actual RLAST.
                if (m_axi_rlast) begin read_busy <= 0; address_sent <= 0; end
            end

            if (frame_running && !streaming && fault == 0 &&
                (fifo_used >= PREFILL_WORDS || (words_issued == FRAME_WORDS && !read_busy)))
                streaming <= 1;
            if (frame_running && streaming && fifo_empty && m_axis_tready)
                starvation_cycles <= starvation_cycles + 1'b1;
            if (pixel_fire) begin
                pixel_lane <= pixel_lane + 1'b1;
                if (x == 0 && y == 0) begin
                    display_started <= 1;
                    displayed_frames <= displayed_frames + 1'b1;
                end
                if (x == IMAGE_WIDTH-1) begin
                    x <= 0;
                    y <= y + 1'b1;
                end else x <= x + 1'b1;
                if (end_of_frame) begin
                    frame_running <= 0;
                    streaming <= 0;
                    if (!completion_fence) fault[3] <= 1;
                    if (completion_fence && fault == 0)
                        completed_frames <= completed_frames + 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (IMAGE_WIDTH < 1 || IMAGE_HEIGHT < 1 || (IMAGE_WIDTH * IMAGE_HEIGHT) % 64 != 0)
            $fatal(1, "ai_frame_scanout requires whole 128-byte RGB565 bursts");
        if (FIFO_WORDS < 64 || (FIFO_WORDS & (FIFO_WORDS-1)) != 0 ||
            PREFILL_WORDS < 16 || PREFILL_WORDS > FIFO_WORDS-16)
            $fatal(1, "ai_frame_scanout invalid FIFO depth/prefill");
    end
`endif
endmodule

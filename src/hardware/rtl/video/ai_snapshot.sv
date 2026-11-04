`timescale 1ns/1ps
// Passive video tap. There is deliberately NO ready output to the video path.
// Only a granted SOF starts a snapshot. An AI FIFO overflow discards that
// snapshot; launched AXI writes drain before its slot can be reused.
module ai_snapshot #(parameter integer IMAGE_WIDTH=1280, IMAGE_HEIGHT=720) (
    input wire clk, resetn, capture_run,
    input wire tap_fire, tap_sof, tap_eol, input wire [15:0] tap_data,
    input wire [31:0] good_count, bad_count,
    output wire idle, input wire start, input wire [31:0] base_addr,
    output reg done, output reg [3:0] error,
    output wire wr_req, input wire wr_accept, output wire [31:0] wr_addr,
    output wire [63:0] wr_data, output wire wr_valid, input wire wr_ready,
    input wire wr_done, wr_error
);
    reg active, ended, aborting, writing;
    reg [1:0] pixel_lane;
    reg [2:0] clear_cycles;
    reg [10:0] x;
    reg [9:0] y;
    reg [47:0] low_pixels;
    reg [31:0] address, good_mark, bad_mark;
    reg [26:0] watchdog;
    wire full, empty, wr_busy, rd_busy;
    wire [10:0] used;
    wire malformed=tap_sof || tap_eol!=(x==IMAGE_WIDTH-1);
    wire push=active && !ended && !aborting && capture_run && tap_fire &&
              !malformed && pixel_lane==3 && !full && bad_count==bad_mark;
    wire fifo_reset=!resetn || clear_cycles!=0;
    assign idle=!active && clear_cycles==0 && !wr_busy && !rd_busy;
    assign wr_req=active && !aborting && !writing && used>=16 && !rd_busy;
    assign wr_addr=address;
    assign wr_valid=writing && !empty;
    wire pop=wr_valid && wr_ready;
    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("block"), .FIFO_WRITE_DEPTH(1024),
        .WRITE_DATA_WIDTH(64), .READ_DATA_WIDTH(64), .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0), .WR_DATA_COUNT_WIDTH(11), .RD_DATA_COUNT_WIDTH(11),
        .USE_ADV_FEATURES("0707"), .PROG_FULL_THRESH(1000), .PROG_EMPTY_THRESH(16),
        .DOUT_RESET_VALUE("0"), .ECC_MODE("no_ecc"), .FULL_RESET_VALUE(0),
        .WAKEUP_TIME(0)
    ) u_fifo (
        .wr_clk(clk), .rst(fifo_reset), .din({tap_data,low_pixels}),
        .wr_en(push), .rd_en(pop), .dout(wr_data), .full(full), .empty(empty),
        .wr_data_count(used), .rd_data_count(), .wr_rst_busy(wr_busy), .rd_rst_busy(rd_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .almost_empty(), .almost_full(), .data_valid(), .dbiterr(), .sbiterr(),
        .overflow(), .underflow(), .prog_empty(), .prog_full(), .wr_ack()
    );
    always @(posedge clk) begin
        if (!resetn) begin
            active<=0; ended<=0; aborting<=0; pixel_lane<=0; writing<=0;
            clear_cycles<=4; x<=0; y<=0; low_pixels<=0; address<=0;
            good_mark<=0; bad_mark<=0; done<=0; error<=0; watchdog<=0;
        end else begin
            done<=0;
            if (clear_cycles!=0) clear_cycles<=clear_cycles-1'b1;
            if (start && idle) begin
                active<=1; ended<=0; aborting<=0; pixel_lane<=1; error<=0;
                x<=1; y<=0; low_pixels<={32'd0,tap_data}; address<=base_addr;
                good_mark<=good_count; bad_mark<=bad_count; watchdog<=0;
                if (!tap_fire || !tap_sof || tap_eol || !capture_run) begin
                    aborting<=1; error<=1;
                end
            end
            if (active) begin
                watchdog<=watchdog+1'b1;
                if (!aborting) begin
                    if (!capture_run || bad_count!=bad_mark) begin
                        aborting<=1; error<=5;
                    end else if (watchdog==27'd99999999) begin
                        aborting<=1; error<=4;
                    end else if (!ended && tap_fire) begin
                        if (malformed) begin aborting<=1; error<=1; end
                        else if (pixel_lane==3 && full) begin aborting<=1; error<=2; end
                        else begin
                            pixel_lane<=pixel_lane+1'b1;
                            case (pixel_lane)
                                0: low_pixels[15:0]<=tap_data;
                                1: low_pixels[31:16]<=tap_data;
                                2: low_pixels[47:32]<=tap_data;
                                default: ;
                            endcase
                            if (x==IMAGE_WIDTH-1) begin
                                x<=0; y<=y+1'b1;
                                if (y==IMAGE_HEIGHT-1) ended<=1;
                            end else x<=x+1'b1;
                        end
                    end
                end
                if (wr_accept) writing<=1;
                if (wr_done) begin
                    writing<=0; address<=address+128;
                    if (wr_error) begin aborting<=1; error<=3; end
                end
                // Include newly accepted transactions in the drain fence.
                if (aborting && !writing && !wr_accept) begin
                    active<=0; done<=1; clear_cycles<=4;
                end else if (!aborting && ended && empty && !writing &&
                             !wr_accept && good_count!=good_mark &&
                             bad_count==bad_mark && capture_run) begin
                    active<=0; done<=1; error<=0; clear_cycles<=4;
                end
            end
        end
    end
endmodule

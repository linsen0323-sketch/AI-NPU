`timescale 1ns / 1ps
// RGB565 + HS/VS/DE -> DVI-compatible TMDS video over an HDMI connector.
// No HDMI audio, EDID or HDCP. Supports fixed 720p mode.
module dvi_transmitter_top (
    input  wire        pixel_clk,
    input  wire        pixel_clk_5x,
    input  wire        reset,
    input  wire [15:0] video_din,
    input  wire        video_hsync,
    input  wire        video_vsync,
    input  wire        video_de,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n
);
    wire [9:0] encoded_b;
    wire [9:0] encoded_g;
    wire [9:0] encoded_r;
    wire [2:0] serial_data;
    wire serial_clock;

    // Only the blue TMDS channel carries HS/VS control bits.
    dvi_encoder u_enc_b (
        .pixel_clk(pixel_clk), .reset(reset),
        .din({video_din[4:0], video_din[4:2]}),
        .c0(video_hsync), .c1(video_vsync), .de(video_de),
        .dout(encoded_b)
    );
    dvi_encoder u_enc_g (
        .pixel_clk(pixel_clk), .reset(reset),
        .din({video_din[10:5], video_din[10:9]}),
        .c0(1'b0), .c1(1'b0), .de(video_de),
        .dout(encoded_g)
    );
    dvi_encoder u_enc_r (
        .pixel_clk(pixel_clk), .reset(reset),
        .din({video_din[15:11], video_din[15:13]}),
        .c0(1'b0), .c1(1'b0), .de(video_de),
        .dout(encoded_r)
    );

    serializer_10_to_1 u_ser_b (
        .reset(reset), .parallel_clk(pixel_clk), .serial_clk_5x(pixel_clk_5x),
        .parallel_data(encoded_b), .serial_data_out(serial_data[0])
    );
    serializer_10_to_1 u_ser_g (
        .reset(reset), .parallel_clk(pixel_clk), .serial_clk_5x(pixel_clk_5x),
        .parallel_data(encoded_g), .serial_data_out(serial_data[1])
    );
    serializer_10_to_1 u_ser_r (
        .reset(reset), .parallel_clk(pixel_clk), .serial_clk_5x(pixel_clk_5x),
        .parallel_data(encoded_r), .serial_data_out(serial_data[2])
    );
    serializer_10_to_1 u_ser_clk (
        .reset(reset), .parallel_clk(pixel_clk), .serial_clk_5x(pixel_clk_5x),
        .parallel_data(10'b1111100000), .serial_data_out(serial_clock)
    );

    OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf_clk (
        .I(serial_clock), .O(tmds_clk_p), .OB(tmds_clk_n)
    );
    genvar ch;
    generate
        for (ch=0; ch<3; ch=ch+1) begin : gen_tmds_obuf
            OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf_data (
                .I(serial_data[ch]), .O(tmds_data_p[ch]), .OB(tmds_data_n[ch])
            );
        end
    endgenerate
endmodule

`timescale 1ns / 1ps
// 50 MHz input -> ~74.21875 MHz pixel clock and 371.09375 MHz 5x clock.
// Both outputs come from the SAME MMCME2_BASE and have an exact 1:5 ratio.
// MMCM: Fvco = 50 * 59.375 / 4 = 742.1875 MHz.
// NOTE: This is a 7-series (Zynq-7000) Xilinx primitive, not generic Verilog.
module clock_gen_720p (
    input  wire sys_clk,
    input  wire sys_rst_n,
    output wire pixel_clk,
    output wire pixel_clk_5x,
    output wire locked
);
    wire clk_fb_mmcm;
    wire clk_fb_buf;
    wire pixel_clk_mmcm;
    wire pixel_clk_5x_mmcm;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(59.375),
        .CLKFBOUT_PHASE(0.0),
        .CLKIN1_PERIOD(20.0),
        .CLKOUT0_DIVIDE_F(10.0),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT1_DIVIDE(2),
        .CLKOUT1_PHASE(0.0),
        .CLKOUT1_DUTY_CYCLE(0.5),
        .DIVCLK_DIVIDE(4),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(sys_clk),
        .CLKFBIN(clk_fb_buf),
        .CLKFBOUT(clk_fb_mmcm),
        .CLKOUT0(pixel_clk_mmcm),
        .CLKOUT1(pixel_clk_5x_mmcm),
        .LOCKED(locked),
        .PWRDWN(1'b0),
        .RST(~sys_rst_n)
    );

    BUFG u_fb_buf  (.I(clk_fb_mmcm),      .O(clk_fb_buf));
    BUFG u_pix_buf (.I(pixel_clk_mmcm),    .O(pixel_clk));
    BUFG u_x5_buf  (.I(pixel_clk_5x_mmcm), .O(pixel_clk_5x));
endmodule

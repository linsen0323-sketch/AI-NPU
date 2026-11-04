`timescale 1ns / 1ps
// Reference clock for a 20-pin OV5640 DVP camera module.
// 50.000 MHz input -> 24.000 MHz output (Fvco = 1200 MHz, /50).
// Uses a dedicated ODDR forwarded-clock output; not a fabric-toggle clock.
// 7-series/Zynq-7000 hardware primitive; synthesis must target Xilinx 7-series.
module cam_xclk_gen (
    input  wire sys_clk,       // 50 MHz from board PL clock input
    input  wire sys_rst_n,     // active-low board reset
    output wire cam_xclk,      // CMOS_XCLK -> FPGA W15 (camera header pin 17)
    output wire locked
);
    wire clkfb_mmcm;
    wire clkfb_buf;
    wire clk24_mmcm;
    wire clk24_buf;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(24.0),
        .CLKFBOUT_PHASE(0.0),
        .CLKIN1_PERIOD(20.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(50.0),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) u_cam_mmcm (
        .CLKIN1(sys_clk),
        .CLKFBIN(clkfb_buf),
        .CLKFBOUT(clkfb_mmcm),
        .CLKOUT0(clk24_mmcm),
        .LOCKED(locked),
        .PWRDWN(1'b0),
        .RST(~sys_rst_n)
    );

    BUFG u_cam_fb_buf (.I(clkfb_mmcm), .O(clkfb_buf));
    BUFG u_cam_clk_buf (.I(clk24_mmcm), .O(clk24_buf));

    // Forward a clean 50% duty cycle output from the IO register.
    // Keep R asserted until the XCLK MMCM locks.
    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b0),
        .SRTYPE("SYNC")
    ) u_cam_clk_out (
        .Q(cam_xclk),
        .C(clk24_buf),
        .CE(1'b1),
        .D1(1'b1),
        .D2(1'b0),
        .R(~locked),
        .S(1'b0)
    );
endmodule

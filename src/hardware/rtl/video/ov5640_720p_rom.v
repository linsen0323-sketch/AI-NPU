`timescale 1ns / 1ps
// OV5640 DVP: 1280x720 RGB565 BE, target ~42 fps, 24 MHz XCLK.
// Keeps module/file name ov5640_720p_rom for drop-in Vivado replacement.
// Full-width 16:9 analog view inherited from working 720p settings:
//   X: 0..2623; Y: 250..1705. Use 2x2 binning / 0x31 increments.
//   The 1312x728 binned window minus offsets (16,4 each side) is 1280x720.
// Output: RGB565, 8-bit parallel DVP (2 PCLK cycles per RGB565 pixel).
// FAST_720P=1: SCLK=84 MHz, HTS=2700, VTS=740 => nominal 42.042 fps.
// Pair 0x3035=0x11 with manual 0x3824=2 to KEEP byte PCLK at 84 MHz.
// A line is 32.143 us; 2560 RGB565 bytes take 30.476 us at 84 MHz.
// VTS=740 leaves 12 lines beyond the 728-row binned sensor window.
// FAST_720P=0 selects the conservative ~30 fps timing (42/1892/740).
// 720p60 RGB565 needs >=110.592 MB/s, above the retained 84 MHz byte bus.
// This profile is source-only; actual capture rate awaits board validation.
// No frame extension in night mode. LENC stays disabled: no module table.
// Initial settings are kept consistent with the duplicate 'final mode' writes.
// References:
// https://files.waveshare.com/upload/d/da/OV5640_DataSheet.pdf
// https://github.com/espressif/esp32-camera/blob/master/sensors/ov5640.c
// https://github.com/torvalds/linux/blob/v6.12/drivers/media/i2c/ov5640.c
// https://github.com/aranzmedical/ov5640/blob/master/ov5640_mipi.c
module ov5640_720p_rom #(
    parameter FAST_720P = 1'b1
) (
    input  wire [8:0] index,
    output reg [23:0] word,
    output reg [15:0] delay_ms,
    output wire [8:0] word_count,
    input wire [7:0] verify_index,
    output reg [23:0] verify_word,
    output reg [7:0] verify_mask,
    output wire [7:0] verify_count
);
    // Use one profile for initial writes, repeated final writes and readback.
    // Never change only the PLL divider: that would double external DVP PCLK.
    localparam [7:0] PLL_SYS_DIV = FAST_720P ? 8'h11 : 8'h21;
    localparam [7:0] PCLK_MANUAL_DIV = FAST_720P ? 8'h02 : 8'h01;
    localparam [15:0] TIMING_HTS = FAST_720P ? 16'd2700 : 16'd1892;
    localparam [15:0] TIMING_VTS = 16'd740;
    localparam integer SENSOR_SCLK_HZ = FAST_720P ? 84000000 : 42000000;
    localparam [15:0] AEC_STEP_50 = SENSOR_SCLK_HZ / (TIMING_HTS * 100);
    localparam [15:0] AEC_STEP_60 = SENSOR_SCLK_HZ / (TIMING_HTS * 120);
    localparam [15:0] AEC_MAX_LINES = TIMING_VTS - 16'd4;
    localparam [7:0] AEC_MAX_BANDS_50 = AEC_MAX_LINES / AEC_STEP_50;
    localparam [7:0] AEC_MAX_BANDS_60 = AEC_MAX_LINES / AEC_STEP_60;
    // 228 SCCB writes, including a repeated final-mode block.
    assign word_count = 9'd228;
    assign verify_count = 8'd55;
    always @(*) begin
        word = 24'h000000;
        delay_ms = 16'd0;
        case (index)
            9'd0: word = 24'h310311;
            9'd1: word = 24'h300882;
            9'd2: word = 24'h300842;
            9'd3: word = 24'h310303;
            9'd4: word = 24'h30177F;
            9'd5: word = 24'h3018FF;
            9'd6: word = 24'h302C02;
            9'd7: word = 24'h310801;
            9'd8: word = 24'h363036;
            9'd9: word = 24'h3632E2;
            9'd10: word = 24'h363312;
            9'd11: word = 24'h3621E0;
            9'd12: word = 24'h3704A0;
            9'd13: word = 24'h37035A;
            9'd14: word = 24'h371578;
            9'd15: word = 24'h371701;
            9'd16: word = 24'h370B60;
            9'd17: word = 24'h37051A;
            9'd18: word = 24'h390502;
            9'd19: word = 24'h390610;
            9'd20: word = 24'h39010A;
            9'd21: word = 24'h373112;
            9'd22: word = 24'h360008;
            9'd23: word = 24'h360133;
            9'd24: word = 24'h302D60;
            9'd25: word = 24'h362052;
            9'd26: word = 24'h371B20;
            9'd27: word = 24'h471C50;
            9'd28: word = 24'h3A1800;
            9'd29: word = 24'h3A19F8;
            9'd30: word = 24'h36351C;
            9'd31: word = 24'h363440;
            9'd32: word = 24'h362201;
            9'd33: word = 24'h3C0428;
            9'd34: word = 24'h3C0598;
            9'd35: word = 24'h3C0600;
            9'd36: word = 24'h3C0707;
            9'd37: word = 24'h3C0800;
            9'd38: word = 24'h3C091C;
            9'd39: word = 24'h3C0A9C;
            9'd40: word = 24'h3C0B40;
            9'd41: word = 24'h382047; // retain vflip bits, enable vertical binning
            9'd42: word = 24'h382101; // retain mirror bits, enable horizontal binning
            9'd43: word = 24'h380000;
            9'd44: word = 24'h380100;
            9'd45: word = 24'h380200;
            9'd46: word = 24'h3803FA;
            9'd47: word = 24'h38040A;
            9'd48: word = 24'h38053F;
            9'd49: word = 24'h380606;
            9'd50: word = 24'h3807A9;
            9'd51: word = 24'h380805;
            9'd52: word = 24'h380900;
            9'd53: word = 24'h380A02;
            9'd54: word = 24'h380BD0;
            9'd55: word = 24'h381000;
            9'd56: word = 24'h381110;
            9'd57: word = 24'h381200;
            9'd58: word = 24'h381304;
            9'd59: word = 24'h381431;
            9'd60: word = 24'h381531;
            9'd61: word = 24'h30341A;
            9'd62: word = {16'h3035, PLL_SYS_DIV};
            9'd63: word = 24'h303669;
            9'd64: word = 24'h303713;
            9'd65: word = 24'h303800;
            9'd66: word = 24'h303900;
            9'd67: word = {16'h380C, TIMING_HTS[15:8]};
            9'd68: word = {16'h380D, TIMING_HTS[7:0]};
            9'd69: word = {16'h380E, TIMING_VTS[15:8]};
            9'd70: word = {16'h380F, TIMING_VTS[7:0]};
            9'd71: word = 24'h3C01B4;
            9'd72: word = 24'h3C0004;
            9'd73: word = {16'h3A08, AEC_STEP_50[15:8]};
            9'd74: word = {16'h3A09, AEC_STEP_50[7:0]};
            9'd75: word = {16'h3A0E, AEC_MAX_BANDS_50};
            9'd76: word = {16'h3A0A, AEC_STEP_60[15:8]};
            9'd77: word = {16'h3A0B, AEC_STEP_60[7:0]};
            9'd78: word = {16'h3A0D, AEC_MAX_BANDS_60};
            9'd79: word = 24'h3A0038;
            9'd80: word = {16'h3A02, AEC_MAX_LINES[15:8]};
            9'd81: word = {16'h3A03, AEC_MAX_LINES[7:0]};
            9'd82: word = {16'h3A14, AEC_MAX_LINES[15:8]};
            9'd83: word = {16'h3A15, AEC_MAX_LINES[7:0]};
            9'd84: word = 24'h361800;
            9'd85: word = 24'h361229;
            9'd86: word = 24'h370864;
            9'd87: word = 24'h370952;
            9'd88: word = 24'h370C03;
            9'd89: word = 24'h400102;
            9'd90: word = 24'h400402; // binned-mode black-level line count
            9'd91: word = 24'h300000;
            9'd92: word = 24'h30021C;
            9'd93: word = 24'h3004FF;
            9'd94: word = 24'h3006C3;
            9'd95: word = 24'h300E58;
            9'd96: word = 24'h302E00;
            9'd97: word = 24'h430061;
            9'd98: word = 24'h501F01;
            9'd99: word = 24'h471303;
            9'd100: word = 24'h440704;
            9'd101: word = 24'h460B35;
            9'd102: word = 24'h460C22;
            9'd103: word = {16'h3824, PCLK_MANUAL_DIV};
            9'd104: word = 24'h500183;
            9'd105: word = 24'h340601;
            9'd106: word = 24'h340004;
            9'd107: word = 24'h340100;
            9'd108: word = 24'h340204;
            9'd109: word = 24'h340300;
            9'd110: word = 24'h340404;
            9'd111: word = 24'h340500;
            9'd112: word = 24'h5180FF;
            9'd113: word = 24'h5181F2;
            9'd114: word = 24'h518200;
            9'd115: word = 24'h518314;
            9'd116: word = 24'h518425;
            9'd117: word = 24'h518524;
            9'd118: word = 24'h518616;
            9'd119: word = 24'h518716;
            9'd120: word = 24'h518816;
            9'd121: word = 24'h518962;
            9'd122: word = 24'h518A62;
            9'd123: word = 24'h518BF0;
            9'd124: word = 24'h518CB2;
            9'd125: word = 24'h518D50;
            9'd126: word = 24'h518E30;
            9'd127: word = 24'h518F30;
            9'd128: word = 24'h519050;
            9'd129: word = 24'h5191F8;
            9'd130: word = 24'h519204;
            9'd131: word = 24'h519370;
            9'd132: word = 24'h5194F0;
            9'd133: word = 24'h5195F0;
            9'd134: word = 24'h519603;
            9'd135: word = 24'h519701;
            9'd136: word = 24'h519804;
            9'd137: word = 24'h519912;
            9'd138: word = 24'h519A04;
            9'd139: word = 24'h519B00;
            9'd140: word = 24'h519C06;
            9'd141: word = 24'h519D82;
            9'd142: word = 24'h519E38;
            9'd143: word = 24'h53811E;
            9'd144: word = 24'h53825B;
            9'd145: word = 24'h538314;
            9'd146: word = 24'h538406;
            9'd147: word = 24'h538582;
            9'd148: word = 24'h538688;
            9'd149: word = 24'h53877C;
            9'd150: word = 24'h538860;
            9'd151: word = 24'h53891C;
            9'd152: word = 24'h538A01;
            9'd153: word = 24'h538B98;
            9'd154: word = 24'h530008;
            9'd155: word = 24'h530130;
            9'd156: word = 24'h53023F;
            9'd157: word = 24'h530310;
            9'd158: word = 24'h530408;
            9'd159: word = 24'h530530;
            9'd160: word = 24'h530618;
            9'd161: word = 24'h530728;
            9'd162: word = 24'h530908;
            9'd163: word = 24'h530A30;
            9'd164: word = 24'h530B04;
            9'd165: word = 24'h530C06;
            9'd166: word = 24'h548001;
            9'd167: word = 24'h548106;
            9'd168: word = 24'h548212;
            9'd169: word = 24'h548324;
            9'd170: word = 24'h54844A;
            9'd171: word = 24'h548558;
            9'd172: word = 24'h548665;
            9'd173: word = 24'h548772;
            9'd174: word = 24'h54887D;
            9'd175: word = 24'h548988;
            9'd176: word = 24'h548A92;
            9'd177: word = 24'h548BA3;
            9'd178: word = 24'h548CB2;
            9'd179: word = 24'h548DC8;
            9'd180: word = 24'h548EDD;
            9'd181: word = 24'h548FF0;
            9'd182: word = 24'h549015;
            9'd183: word = 24'h500027;
            9'd184: word = 24'h500183;
            9'd185: word = 24'h340600;
            9'd186: word = 24'h350300;
            9'd187: word = 24'h3A0F30;
            9'd188: word = 24'h3A1028;
            9'd189: word = 24'h3A1B30;
            9'd190: word = 24'h3A1E28;
            9'd191: word = 24'h3A1161;
            9'd192: word = 24'h3A1F14;
            9'd193: word = 24'h40051A;
            9'd194: word = {16'h3035, PLL_SYS_DIV};
            9'd195: word = 24'h303669;
            9'd196: word = 24'h474020;
            9'd197: word = 24'h380000;
            9'd198: word = 24'h380100;
            9'd199: word = 24'h380200;
            9'd200: word = 24'h3803FA;
            9'd201: word = 24'h38040A;
            9'd202: word = 24'h38053F;
            9'd203: word = 24'h380606;
            9'd204: word = 24'h3807A9;
            9'd205: word = 24'h380805;
            9'd206: word = 24'h380900;
            9'd207: word = 24'h380A02;
            9'd208: word = 24'h380BD0;
            9'd209: word = {16'h380C, TIMING_HTS[15:8]};
            9'd210: word = {16'h380D, TIMING_HTS[7:0]};
            9'd211: word = {16'h380E, TIMING_VTS[15:8]};
            9'd212: word = {16'h380F, TIMING_VTS[7:0]};
            9'd213: word = 24'h381431;
            9'd214: word = 24'h381531;
            9'd215: word = {16'h3824, PCLK_MANUAL_DIV};
            9'd216: word = 24'h430061;
            9'd217: word = 24'h501F01;
            9'd218: word = 24'h503D00;
            9'd219: word = 24'h36310E;
            9'd220: word = 24'h3A1343;
            9'd221: word = 24'h3A0101;
            9'd222: word = 24'h350C00;
            9'd223: word = 24'h350D00;
            9'd224: word = 24'h502500;
            9'd225: word = 24'h500536;
            9'd226: word = 24'h530825;
            9'd227: word = 24'h300802;
            default: word = 24'h000000;
        endcase
        if (index == 9'd1) delay_ms = 16'd20; // software reset settle
        if (index == 9'd64) delay_ms = 16'd5; // PLL settle
    end
    always @(*) begin
        verify_word = 24'h000000;
        verify_mask = 8'h00;
        case (verify_index)
            8'd0: begin verify_word = 24'h300A56; verify_mask = 8'hFF; end
            8'd1: begin verify_word = 24'h300B40; verify_mask = 8'hFF; end
            8'd2: begin verify_word = 24'h300802; verify_mask = 8'h42; end
            8'd3: begin verify_word = 24'h30341A; verify_mask = 8'h0F; end
            8'd4: begin verify_word = {16'h3035, PLL_SYS_DIV}; verify_mask = 8'hFF; end
            8'd5: begin verify_word = 24'h303669; verify_mask = 8'hFF; end
            8'd6: begin verify_word = 24'h303713; verify_mask = 8'h1F; end
            8'd7: begin verify_word = 24'h310801; verify_mask = 8'h3F; end
            8'd8: begin verify_word = 24'h380000; verify_mask = 8'hFF; end
            8'd9: begin verify_word = 24'h380100; verify_mask = 8'hFF; end
            8'd10: begin verify_word = 24'h380200; verify_mask = 8'hFF; end
            8'd11: begin verify_word = 24'h3803FA; verify_mask = 8'hFF; end
            8'd12: begin verify_word = 24'h38040A; verify_mask = 8'hFF; end
            8'd13: begin verify_word = 24'h38053F; verify_mask = 8'hFF; end
            8'd14: begin verify_word = 24'h380606; verify_mask = 8'hFF; end
            8'd15: begin verify_word = 24'h3807A9; verify_mask = 8'hFF; end
            8'd16: begin verify_word = 24'h380805; verify_mask = 8'hFF; end
            8'd17: begin verify_word = 24'h380900; verify_mask = 8'hFF; end
            8'd18: begin verify_word = 24'h380A02; verify_mask = 8'hFF; end
            8'd19: begin verify_word = 24'h380BD0; verify_mask = 8'hFF; end
            8'd20: begin verify_word = {16'h380C, TIMING_HTS[15:8]}; verify_mask = 8'hFF; end
            8'd21: begin verify_word = {16'h380D, TIMING_HTS[7:0]}; verify_mask = 8'hFF; end
            8'd22: begin verify_word = {16'h380E, TIMING_VTS[15:8]}; verify_mask = 8'hFF; end
            8'd23: begin verify_word = {16'h380F, TIMING_VTS[7:0]}; verify_mask = 8'hFF; end
            8'd24: begin verify_word = 24'h381000; verify_mask = 8'hFF; end
            8'd25: begin verify_word = 24'h381110; verify_mask = 8'hFF; end
            8'd26: begin verify_word = 24'h381200; verify_mask = 8'hFF; end
            8'd27: begin verify_word = 24'h381304; verify_mask = 8'hFF; end
            8'd28: begin verify_word = 24'h381431; verify_mask = 8'hFF; end
            8'd29: begin verify_word = 24'h381531; verify_mask = 8'hFF; end
            8'd30: begin verify_word = 24'h382047; verify_mask = 8'hFF; end
            8'd31: begin verify_word = 24'h382101; verify_mask = 8'hFF; end
            8'd32: begin verify_word = 24'h430061; verify_mask = 8'hFF; end
            8'd33: begin verify_word = 24'h501F01; verify_mask = 8'hFF; end
            8'd34: begin verify_word = 24'h503D00; verify_mask = 8'hFF; end
            8'd35: begin verify_word = 24'h500027; verify_mask = 8'hFF; end
            8'd36: begin verify_word = 24'h500183; verify_mask = 8'hFF; end
            8'd37: begin verify_word = 24'h340600; verify_mask = 8'h01; end
            8'd38: begin verify_word = 24'h350300; verify_mask = 8'h03; end
            8'd39: begin verify_word = 24'h3A0038; verify_mask = 8'h7C; end
            8'd40: begin verify_word = {16'h3A02, AEC_MAX_LINES[15:8]}; verify_mask = 8'hFF; end
            8'd41: begin verify_word = {16'h3A03, AEC_MAX_LINES[7:0]}; verify_mask = 8'hFF; end
            8'd42: begin verify_word = {16'h3A14, AEC_MAX_LINES[15:8]}; verify_mask = 8'hFF; end
            8'd43: begin verify_word = {16'h3A15, AEC_MAX_LINES[7:0]}; verify_mask = 8'hFF; end
            8'd44: begin verify_word = {16'h3A08, AEC_STEP_50[15:8]}; verify_mask = 8'hFF; end
            8'd45: begin verify_word = {16'h3A09, AEC_STEP_50[7:0]}; verify_mask = 8'hFF; end
            8'd46: begin verify_word = {16'h3A0A, AEC_STEP_60[15:8]}; verify_mask = 8'hFF; end
            8'd47: begin verify_word = {16'h3A0B, AEC_STEP_60[7:0]}; verify_mask = 8'hFF; end
            8'd48: begin verify_word = {16'h3A0D, AEC_MAX_BANDS_60}; verify_mask = 8'hFF; end
            8'd49: begin verify_word = {16'h3A0E, AEC_MAX_BANDS_50}; verify_mask = 8'hFF; end
            8'd50: begin verify_word = 24'h3C0004; verify_mask = 8'hFF; end
            8'd51: begin verify_word = 24'h3C01B4; verify_mask = 8'hFF; end
            8'd52: begin verify_word = 24'h474020; verify_mask = 8'h23; end
            8'd53: begin verify_word = 24'h460C22; verify_mask = 8'h22; end
            8'd54: begin verify_word = {16'h3824, PCLK_MANUAL_DIV}; verify_mask = 8'h1F; end
            default: begin verify_word = 24'h000000; verify_mask = 8'h00; end
        endcase
    end
endmodule


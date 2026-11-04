`timescale 1ns/1ps
// Source updated for both profiles; rerun explicitly when simulation is wanted.
module tb_ov5640_profile #(
    parameter FAST_720P = 1'b1
);
    reg [8:0] index = 0;
    reg [7:0] verify_index = 0;
    wire [23:0] word, verify_word;
    wire [15:0] delay_ms;
    wire [8:0] word_count;
    wire [7:0] verify_count, verify_mask;
    reg [7:0] registers [0:65535];
    bit written [0:65535];
    integer i, pll_writes;

    ov5640_720p_rom #(.FAST_720P(FAST_720P)) dut (.*);

    task automatic expect_register(input integer address, input reg [7:0] value);
        if (!written[address] || registers[address] !== value)
            $fatal(1, "Register %04h expected %02h, got %02h", address, value, registers[address]);
    endtask

    initial begin
        #10000;
        $fatal(1, "Watchdog: camera profile test did not finish");
    end

    initial begin
        pll_writes = 0;
        // Read-only silicon identification is supplied by the sensor itself.
        registers['h300a] = 'h56; written['h300a] = 1;
        registers['h300b] = 'h40; written['h300b] = 1;
        #1;
        if (word_count != 228 || verify_count != 55)
            $fatal(1, "Unexpected SCCB table lengths");
        for (i = 0; i < word_count; i = i + 1) begin
            index = i;
            #1;
            if ($isunknown(word) || word[23:8] == 0)
                $fatal(1, "Invalid write at index %0d", i);
            registers[word[23:8]] = word[7:0];
            written[word[23:8]] = 1;
            if (word[23:8] == 16'h3035) begin
                pll_writes = pll_writes + 1;
                if (word[7:0] != (FAST_720P ? 8'h11 : 8'h21))
                    $fatal(1, "Unexpected PLL profile at write %0d", i);
            end
        end
        if (pll_writes != 2) $fatal(1, "Expected both PLL mode writes");
        // Both profiles retain nominal 84 MHz external DVP, 24 MHz XCLK.
        expect_register('h3034, 'h1a);
        expect_register('h3035, FAST_720P ? 'h11 : 'h21);
        expect_register('h3036, 'h69); expect_register('h3037, 'h13);
        expect_register('h3108, 'h01); expect_register('h460c, 'h22);
        expect_register('h3824, FAST_720P ? 'h02 : 'h01);
        // Preserve the analog window; bin to 1280x720, RGB565 high byte first.
        expect_register('h3800, 'h00); expect_register('h3801, 'h00);
        expect_register('h3802, 'h00); expect_register('h3803, 'hfa);
        expect_register('h3804, 'h0a); expect_register('h3805, 'h3f);
        expect_register('h3806, 'h06); expect_register('h3807, 'ha9);
        expect_register('h3808, 'h05); expect_register('h3809, 'h00);
        expect_register('h380a, 'h02); expect_register('h380b, 'hd0);
        expect_register('h380c, FAST_720P ? 'h0a : 'h07);
        expect_register('h380d, FAST_720P ? 'h8c : 'h64);
        expect_register('h380e, 'h02); expect_register('h380f, 'he4);
        expect_register('h3814, 'h31); expect_register('h3815, 'h31);
        expect_register('h3820, 'h47); expect_register('h3821, 'h01);
        expect_register('h4004, 'h02);
        expect_register('h4300, 'h61); expect_register('h501f, 'h01);
        expect_register('h503d, 'h00);
        // Anti-banding and exposure limits must follow SCLK and line length.
        expect_register('h3a08, FAST_720P ? 'h01 : 'h00);
        expect_register('h3a09, FAST_720P ? 'h37 : 'hdd);
        expect_register('h3a0a, FAST_720P ? 'h01 : 'h00);
        expect_register('h3a0b, FAST_720P ? 'h03 : 'hb8);
        expect_register('h3a0d, FAST_720P ? 'h02 : 'h04);
        expect_register('h3a0e, FAST_720P ? 'h02 : 'h03);
        expect_register('h3a00, 'h38);
        expect_register('h3a02, 'h02); expect_register('h3a03, 'he0);
        expect_register('h3a14, 'h02); expect_register('h3a15, 'he0);
        // Every readback expectation must agree with the final written value.
        for (i = 0; i < verify_count; i = i + 1) begin
            verify_index = i;
            #1;
            if ($isunknown({verify_word, verify_mask}) || verify_mask == 0 ||
                !written[verify_word[23:8]] ||
                ((registers[verify_word[23:8]] ^ verify_word[7:0]) & verify_mask) != 0)
                $fatal(1, "Readback mismatch at index %0d, register %04h", i, verify_word[23:8]);
        end
        $display("TEST_PASS: 228 SCCB writes, 55 readbacks, FAST_720P=%0d clock/geometry/AEC contract", FAST_720P);
        $finish;
    end
endmodule

`timescale 1ns / 1ps
// Autonomous OV5640 initialization with ACK checks, bounded retries, masked
// read-back verification, and an ISP convergence interval before capture.
// init_failed is sticky until reset; init_done never asserts on a failed init.
module ov5640_sccb_ctrl #(
    parameter integer CLK_HZ = 50000000,
    parameter integer SCCB_HZ = 100000,
    parameter integer MAX_RETRIES = 3,
    parameter integer RESET_MS = 2,
    parameter integer STARTUP_MS = 30,
    parameter integer WARMUP_MS = 300
) (
    input wire clk_50m,
    input wire reset_n,
    input wire xclk_locked,
    inout wire cam_scl,
    inout wire cam_sda,
    output wire cam_rst_n,
    output wire cam_pwdn,
    output reg init_done,
    output reg init_failed,
    output reg nack_seen,
    output reg [8:0] config_index,
    output reg [7:0] verify_index,
    output reg [15:0] diag_reg,
    output reg [7:0] diag_expected,
    output reg [7:0] diag_readback,
    output reg [3:0] diag_error,
    output reg [15:0] retry_count
);
    // This level was chip-ID/stream validated for the existing camera module.
    assign cam_pwdn = 1'b0;
    localparam integer MS_CYCLES = (CLK_HZ < 1000) ? 1 : CLK_HZ / 1000;
    localparam integer RESET_CYCLES = MS_CYCLES * RESET_MS;
    localparam integer STARTUP_CYCLES = MS_CYCLES * STARTUP_MS;
    reg [31:0] startup;
    reg [31:0] ms_div;
    wire ms_tick = (ms_div == MS_CYCLES-1);
    wire controller_reset_n = reset_n && xclk_locked;
    assign cam_rst_n = controller_reset_n && (startup >= RESET_CYCLES);
    always @(posedge clk_50m or negedge reset_n) begin
        if (!reset_n) begin startup <= 0; ms_div <= 0; end
        else if (!xclk_locked) begin startup <= 0; ms_div <= 0; end
        else begin
            if (startup < STARTUP_CYCLES) startup <= startup + 1'b1;
            if (ms_tick) ms_div <= 0;
            else ms_div <= ms_div + 1'b1;
        end
    end

    wire [23:0] config_word, verify_word;
    wire [15:0] config_delay_ms;
    wire [8:0] config_count;
    wire [7:0] verify_count, verify_mask;
    ov5640_720p_rom u_rom (
        .index(config_index), .word(config_word),
        .delay_ms(config_delay_ms), .word_count(config_count),
        .verify_index(verify_index), .verify_word(verify_word),
        .verify_mask(verify_mask), .verify_count(verify_count)
    );

    reg request, read_request;
    reg [15:0] request_addr;
    reg [7:0] request_data;
    wire bus_busy, bus_done;
    wire [3:0] bus_error;
    wire [7:0] bus_readback;
    camera_sccb_master #(.CLK_HZ(CLK_HZ), .SCCB_HZ(SCCB_HZ)) u_bus (
        .clk(clk_50m), .reset_n(controller_reset_n),
        .request(request), .read_request(read_request),
        .reg_addr(request_addr), .write_data(request_data),
        .busy(bus_busy), .done(bus_done), .error_code(bus_error),
        .read_data(bus_readback), .scl(cam_scl), .sda(cam_sda)
    );

    localparam [3:0] ST_BOOT=0, ST_WRITE_LOAD=1, ST_WRITE_WAIT=2,
        ST_WRITE_DELAY=3, ST_WRITE_ADVANCE=4, ST_READ_LOAD=5,
        ST_READ_WAIT=6, ST_READ_ADVANCE=7, ST_RETRY_WRITE=8,
        ST_RETRY_READ=9, ST_WARMUP=10, ST_DONE=11, ST_FAILED=12;
    reg [3:0] state;
    reg [15:0] delay_left;
    reg [7:0] attempt;
    wire verify_matches = ((bus_readback & verify_mask) ==
                           (verify_word[7:0] & verify_mask));
    always @(posedge clk_50m or negedge reset_n) begin
        if (!reset_n) begin
            state <= ST_BOOT; request <= 0; read_request <= 0;
            request_addr <= 0; request_data <= 0;
            init_done <= 0; init_failed <= 0; nack_seen <= 0;
            config_index <= 0; verify_index <= 0; delay_left <= 0;
            attempt <= 0; diag_reg <= 0; diag_expected <= 0;
            diag_readback <= 0; diag_error <= 0; retry_count <= 0;
        end else if (!xclk_locked) begin
            state <= ST_BOOT; request <= 0; read_request <= 0;
            request_addr <= 0; request_data <= 0;
            init_done <= 0; init_failed <= 0; nack_seen <= 0;
            config_index <= 0; verify_index <= 0; delay_left <= 0;
            attempt <= 0; diag_reg <= 0; diag_expected <= 0;
            diag_readback <= 0; diag_error <= 0; retry_count <= 0;
        end else begin
            request <= 0;
            case (state)
                ST_BOOT: if (startup >= STARTUP_CYCLES) state <= ST_WRITE_LOAD;
                ST_WRITE_LOAD: if (!bus_busy) begin
                    request_addr <= config_word[23:8];
                    request_data <= config_word[7:0];
                    read_request <= 0; request <= 1;
                    diag_reg <= config_word[23:8];
                    diag_expected <= config_word[7:0];
                    state <= ST_WRITE_WAIT;
                end
                ST_WRITE_WAIT: if (bus_done) begin
                    if (bus_error != 0) begin
                        diag_error <= bus_error;
                        if (bus_error == 1) nack_seen <= 1;
                        if (attempt < MAX_RETRIES) begin
                            attempt <= attempt + 1'b1;
                            if (retry_count != 16'hffff) retry_count <= retry_count + 1'b1;
                            delay_left <= 16'd2; state <= ST_RETRY_WRITE;
                        end else begin init_failed <= 1; state <= ST_FAILED; end
                    end else begin
                        attempt <= 0; diag_error <= 0;
                        if (config_delay_ms != 0) begin
                            delay_left <= config_delay_ms; state <= ST_WRITE_DELAY;
                        end else state <= ST_WRITE_ADVANCE;
                    end
                end
                ST_WRITE_DELAY: if (ms_tick) begin
                    // The zero check on the following tick gives at least the
                    // requested delay irrespective of transaction/tick phase.
                    if (delay_left == 0) state <= ST_WRITE_ADVANCE;
                    else delay_left <= delay_left - 1'b1;
                end
                ST_WRITE_ADVANCE: begin
                    if (config_index == config_count-1'b1) begin
                        verify_index <= 0; state <= ST_READ_LOAD;
                    end else begin config_index <= config_index + 1'b1; state <= ST_WRITE_LOAD; end
                end
                ST_READ_LOAD: if (!bus_busy) begin
                    request_addr <= verify_word[23:8]; request_data <= 0;
                    read_request <= 1; request <= 1;
                    diag_reg <= verify_word[23:8]; diag_expected <= verify_word[7:0];
                    state <= ST_READ_WAIT;
                end
                ST_READ_WAIT: if (bus_done) begin
                    diag_readback <= bus_readback;
                    if ((bus_error != 0) || !verify_matches) begin
                        diag_error <= (bus_error != 0) ? bus_error : 4'd2;
                        if (bus_error == 1) nack_seen <= 1;
                        if (attempt < MAX_RETRIES) begin
                            attempt <= attempt + 1'b1;
                            if (retry_count != 16'hffff) retry_count <= retry_count + 1'b1;
                            delay_left <= 16'd2; state <= ST_RETRY_READ;
                        end else begin init_failed <= 1; state <= ST_FAILED; end
                    end else begin attempt <= 0; diag_error <= 0; state <= ST_READ_ADVANCE; end
                end
                ST_READ_ADVANCE: begin
                    if (verify_index == verify_count-1'b1) begin
                        delay_left <= WARMUP_MS; state <= ST_WARMUP;
                    end else begin verify_index <= verify_index + 1'b1; state <= ST_READ_LOAD; end
                end
                ST_RETRY_WRITE: if (ms_tick) begin
                    if (delay_left == 0) state <= ST_WRITE_LOAD;
                    else delay_left <= delay_left - 1'b1;
                end
                ST_RETRY_READ: if (ms_tick) begin
                    if (delay_left == 0) state <= ST_READ_LOAD;
                    else delay_left <= delay_left - 1'b1;
                end
                ST_WARMUP: if (ms_tick) begin
                    if (delay_left == 0) begin init_done <= 1; state <= ST_DONE; end
                    else delay_left <= delay_left - 1'b1;
                end
                ST_DONE: init_done <= 1;
                ST_FAILED: begin init_done <= 0; init_failed <= 1; end
                default: begin init_done <= 0; init_failed <= 1; state <= ST_FAILED; end
            endcase
        end
    end
endmodule

// 16-bit-register / 8-bit-data SCCB master at slave address 0x3c.
// Writes: START 78 addr_hi addr_lo data STOP.
// Reads: START 78 addr_hi addr_lo repeated-START 79 data NACK STOP.
// Both signals are open-drain: the module/board must provide pull-ups.
// error_code: 1 NACK, 3 SCL timeout, 4 SDA busy before START.
module camera_sccb_master #(
    parameter integer CLK_HZ = 50000000,
    parameter integer SCCB_HZ = 100000,
    parameter integer STRETCH_LIMIT = 400
) (
    input wire clk, input wire reset_n,
    input wire request, input wire read_request,
    input wire [15:0] reg_addr, input wire [7:0] write_data,
    output reg busy, output reg done,
    output reg [3:0] error_code, output reg [7:0] read_data,
    inout wire scl, inout wire sda
);
    localparam integer QUARTER_CYCLES = (CLK_HZ/(4*SCCB_HZ) < 1) ? 1 : CLK_HZ/(4*SCCB_HZ);
    localparam integer DIV_WIDTH = (QUARTER_CYCLES <= 1) ? 1 : $clog2(QUARTER_CYCLES);
    reg [DIV_WIDTH-1:0] divider;
    wire tick = (divider == QUARTER_CYCLES-1);
    reg scl_low, sda_low;
    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] scl_sync, sda_sync;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin scl_sync <= 2'b11; sda_sync <= 2'b11; divider <= 0; end
        else begin
            scl_sync <= {scl_sync[0],scl}; sda_sync <= {sda_sync[0],sda};
            if (tick) divider <= 0; else divider <= divider + 1'b1;
        end
    end
    localparam [3:0] B_IDLE=0, B_START=1, B_SEND=2, B_ACK=3,
        B_RESTART=4, B_READ=5, B_NACK=6, B_STOP=7;
    reg [3:0] state;
    reg [1:0] phase;
    reg [2:0] bit_index;
    reg [1:0] byte_index;
    reg [15:0] saved_addr;
    reg [7:0] saved_data;
    reg saved_read, nack;
    reg [15:0] stretch_count;
    reg [7:0] tx_byte;
    always @(*) begin
        case (byte_index)
            0: tx_byte = 8'h78;
            1: tx_byte = saved_addr[15:8];
            2: tx_byte = saved_addr[7:0];
            default: tx_byte = saved_read ? 8'h79 : saved_data;
        endcase
    end
    wire wait_high = ((state == B_START) && (phase == 1)) ||
                     ((state != B_IDLE) && (state != B_START) && (phase == 2));
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= B_IDLE; phase <= 0; bit_index <= 7; byte_index <= 0;
            saved_addr <= 0; saved_data <= 0; saved_read <= 0;
            busy <= 0; done <= 0; error_code <= 0; read_data <= 0;
            scl_low <= 0; sda_low <= 0; nack <= 0; stretch_count <= 0;
        end else begin
            done <= 0;
            if ((state == B_IDLE) && request) begin
                saved_addr <= reg_addr; saved_data <= write_data; saved_read <= read_request;
                read_data <= 0; error_code <= 0; nack <= 0;
                phase <= 0; bit_index <= 7; byte_index <= 0; stretch_count <= 0;
                busy <= 1; state <= B_START;
            end else if (tick) begin
                if (wait_high && !scl_sync[1]) begin
                    if (stretch_count == STRETCH_LIMIT-1) begin
                        error_code <= 4'd3; done <= 1; busy <= 0;
                        scl_low <= 0; sda_low <= 0; state <= B_IDLE; stretch_count <= 0;
                    end else stretch_count <= stretch_count + 1'b1;
                end else begin
                    stretch_count <= 0;
                    case (state)
                        B_IDLE: begin scl_low <= 0; sda_low <= 0; end
                        B_START: case (phase)
                            0: begin scl_low <= 0; sda_low <= 0; phase <= 1; end
                            1: if (!sda_sync[1]) begin
                                error_code <= 4'd4; done <= 1; busy <= 0; state <= B_IDLE;
                            end else begin sda_low <= 1; phase <= 2; end
                            2: begin scl_low <= 1; phase <= 3; end
                            3: begin phase <= 0; state <= B_SEND; end
                        endcase
                        B_SEND: case (phase)
                            0: begin scl_low <= 1; sda_low <= !tx_byte[bit_index]; phase <= 1; end
                            1: begin scl_low <= 0; phase <= 2; end
                            2: phase <= 3;
                            3: begin
                                scl_low <= 1; phase <= 0;
                                if (bit_index == 0) state <= B_ACK;
                                else bit_index <= bit_index - 1'b1;
                            end
                        endcase
                        B_ACK: case (phase)
                            0: begin scl_low <= 1; sda_low <= 0; phase <= 1; end
                            1: begin scl_low <= 0; phase <= 2; end
                            2: begin
                                if (sda_sync[1]) begin nack <= 1; error_code <= 4'd1; end
                                phase <= 3;
                            end
                            3: begin
                                scl_low <= 1; phase <= 0; bit_index <= 7;
                                if (nack) state <= B_STOP;
                                else if (saved_read && (byte_index == 2)) state <= B_RESTART;
                                else if (byte_index == 3) state <= saved_read ? B_READ : B_STOP;
                                else begin byte_index <= byte_index + 1'b1; state <= B_SEND; end
                            end
                        endcase
                        B_RESTART: case (phase)
                            0: begin scl_low <= 1; sda_low <= 0; phase <= 1; end
                            1: begin scl_low <= 0; phase <= 2; end
                            2: begin sda_low <= 1; phase <= 3; end
                            3: begin scl_low <= 1; byte_index <= 3; phase <= 0; state <= B_SEND; end
                        endcase
                        B_READ: case (phase)
                            0: begin scl_low <= 1; sda_low <= 0; phase <= 1; end
                            1: begin scl_low <= 0; phase <= 2; end
                            2: begin read_data[bit_index] <= sda_sync[1]; phase <= 3; end
                            3: begin
                                scl_low <= 1; phase <= 0;
                                if (bit_index == 0) state <= B_NACK;
                                else bit_index <= bit_index - 1'b1;
                            end
                        endcase
                        B_NACK: case (phase)
                            0: begin scl_low <= 1; sda_low <= 0; phase <= 1; end
                            1: begin scl_low <= 0; phase <= 2; end
                            2: phase <= 3;
                            3: begin scl_low <= 1; phase <= 0; state <= B_STOP; end
                        endcase
                        B_STOP: case (phase)
                            0: begin scl_low <= 1; sda_low <= 1; phase <= 1; end
                            1: begin scl_low <= 0; phase <= 2; end
                            2: begin sda_low <= 0; phase <= 3; end
                            3: begin busy <= 0; done <= 1; phase <= 0; state <= B_IDLE; end
                        endcase
                        default: begin
                            error_code <= 4'd4; done <= 1; busy <= 0;
                            scl_low <= 0; sda_low <= 0; state <= B_IDLE;
                        end
                    endcase
                end
            end
        end
    end
endmodule

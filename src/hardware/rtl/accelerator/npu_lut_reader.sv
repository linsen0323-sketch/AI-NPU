`timescale 1ns/1ps

// Host-resolved LUT descriptors over the scalar memory request interface.
// Constant memory must remain immutable while its configuration is active.
// Reset must be shared with the scalar transport and its AXI path if busy.
(* use_dsp = "no" *)
module npu_lut_reader #(
    parameter integer CACHE_ENABLE=1,
    // Opt-in until functional simulation and a new resource build validate it.
    parameter bit ENABLE_LUT_TDP=1'b0
) (
    input  wire clk,
    input  wire rst_n,

    input  wire config_valid,
    output wire config_ready,
    input  wire [31:0] const_base,
    input  wire [31:0] const_bytes,
    input  wire [31:0] sigmoid_base,
    input  wire [31:0] sigmoid_entries,
    input  wire [2:0] sigmoid_dtype,
    input  wire [31:0] exp_base,
    input  wire [31:0] exp_entries,
    input  wire [2:0] exp_dtype,
    output wire config_rsp_valid,
    input  wire config_rsp_ready,
    output reg [3:0] config_rsp_fault,

    input  wire req_valid,
    output wire req_ready,
    input  wire [1:0] req_kind,
    input  wire [12:0] req_index,
    output wire rsp_valid,
    input  wire rsp_ready,
    output reg signed [63:0] rsp_y0,
    output reg signed [63:0] rsp_y1,
    output reg [3:0] rsp_fault,

    output wire stream_available,
    input wire stream_req_valid,
    output wire stream_req_ready,
    input wire [1:0] stream_req_kind,
    input wire [12:0] stream_req_index,
    output reg stream_rsp_valid,
    input wire stream_rsp_ready,
    output reg signed [63:0] stream_rsp_y0,stream_rsp_y1,
    output reg [3:0] stream_rsp_fault,

    output wire scalar_req_valid,
    input  wire scalar_req_ready,
    output wire scalar_req_write,
    output wire [31:0] scalar_req_addr,
    output wire [1:0] scalar_req_size,
    output wire [63:0] scalar_req_wdata,
    input  wire scalar_rsp_valid,
    output wire scalar_rsp_ready,
    input  wire signed [63:0] scalar_rsp_rdata,
    input  wire [3:0] scalar_rsp_fault
);
    localparam [2:0] DTYPE_I32 = 3'd3, DTYPE_I64 = 3'd4;
    localparam [1:0] LUT_SIGMOID = 2'd0, LUT_EXP = 2'd1;
    localparam [3:0] IDLE         = 4'd0,
                     CONFIG_REPLY = 4'd1,
                     CHECK_LOOKUP = 4'd2,
                     READ0_SEND   = 4'd3,
                     READ0_WAIT   = 4'd4,
                     READ1_SEND   = 4'd5,
                     READ1_WAIT   = 4'd6,
                     LOOKUP_REPLY = 4'd7,
                     CONFIG_CHECK = 4'd8,
                     CONFIG_COMMIT = 4'd9,
                     SELECT_LOOKUP = 4'd10,
                     CALC_LOOKUP   = 4'd11,
                     PAIR_LOOKUP   = 4'd12,
                     COMMIT_LOOKUP = 4'd13, CACHE_REPLY=4'd14;
    localparam integer FAULT_DESCRIPTOR = 0,
                       FAULT_ALIGNMENT = 1,
                       FAULT_BOUNDS = 2,
                       FAULT_SCALAR = 3;

    reg [3:0] state;
    reg configured_q;
    reg [31:0] const_base_q, const_bytes_q;
    reg [31:0] sigmoid_base_q, sigmoid_entries_q;
    reg [31:0] exp_base_q, exp_entries_q;
    reg [2:0] sigmoid_dtype_q, exp_dtype_q;
    // Pending descriptors are separate from the active set so an invalid
    // configuration can be rejected without changing subsequent lookups.
    reg [31:0] const_base_pending, const_bytes_pending;
    reg [31:0] sigmoid_base_pending, sigmoid_entries_pending;
    reg [31:0] exp_base_pending, exp_entries_pending;
    reg [2:0] sigmoid_dtype_pending, exp_dtype_pending;
    reg [1:0] kind_q;
    reg [12:0] index_q;
    reg [31:0] address0_q, address1_q;
    reg [1:0] scalar_size_q;
    reg [31:0] selected_base, selected_entries;
    reg [2:0] selected_dtype;
    // Break descriptor selection, address arithmetic, range checks, and the
    // scalar-address write enable into separate registered stages. These
    // payloads are overwritten before use after every lookup handshake.
    reg [31:0] lookup_base_q, lookup_entries_q;
    reg [2:0] lookup_dtype_q;
    reg [13:0] successor_index_q;
    reg [35:0] region_end_q, table_end_q;
    reg [35:0] address0_wide_q, address1_wide_q, pair_end_q;
    reg [3:0] lookup_fault;

    // Full descriptor-scoped cache: two 8193-entry signed64 tables. Both
    // interpolation endpoints use synchronous one-cycle memory reads.
    // Configuration is acknowledged only after all reads have drained. An
    // invalid descriptor preserves the prior cache. A fill error preserves
    // prior descriptors and falls back to scalar reads for that old set.
    wire signed [63:0] cache_y0,cache_y1;
    reg cache_valid,fill_mode,fill_complete,fill_kind;
    reg [13:0] fill_index;
    reg signed [63:0] sigmoid_endpoint,exp_endpoint;
    wire cache_eligible=CACHE_ENABLE && sigmoid_entries_pending<=8193 && exp_entries_pending<=8193;
    wire [13:0] cache_addr0={kind_q[0],index_q};
    // Keep both successor candidates before the ownership mux. Factoring
    // these adders into (stream_fire ? stream_addr : cache_addr0)+1 puts a
    // 14-bit carry chain after configuration/backpressure control. The
    // addresses, RAM enable, valid tags and result cycles are unchanged.
    (* keep="true" *) wire [13:0] cache_addr1=cache_addr0+14'd1;
    wire cache_write=fill_mode && state==READ0_WAIT && scalar_rsp_valid && scalar_rsp_ready && scalar_rsp_fault==0;
    reg stream_stage_valid,stream_endpoint,stream_kind;
    reg [3:0] stream_fault;
    wire stream_output_ready=!stream_rsp_valid || stream_rsp_ready;
    wire stream_stage_ready=!stream_stage_valid || stream_output_ready;
    wire stream_idle=!stream_stage_valid && !stream_rsp_valid;
    wire stream_fire=stream_req_valid && stream_req_ready;
    wire [13:0] stream_addr={stream_req_kind[0],stream_req_index};
    (* keep="true" *) wire [13:0] stream_addr1=stream_addr+14'd1;
    wire cache_read=stream_fire || (state==COMMIT_LOOKUP && cache_valid && rsp_fault==0);
    wire [13:0] cache_read_addr0=stream_fire ? stream_addr : cache_addr0;
    wire [13:0] cache_read_addr1=stream_fire ? stream_addr1 : cache_addr1;
    assign stream_available=configured_q && cache_valid;
    assign stream_req_ready=rst_n && state==IDLE && !config_valid && !req_valid &&
                            stream_available && stream_stage_ready;
    generate if(ENABLE_LUT_TDP && CACHE_ENABLE)begin:g_tdp_cache
        // 14-bit WORD addresses: {table kind, 13-bit index}, no byte shift.
        // A fills OR reads y0; B reads y1. Fill and lookup are mutually
        // exclusive in the existing FSM, including both elastic result slots.
        wire memory_write=cache_write && !fill_index[13];
        wire [13:0] address_a=memory_write ? {fill_kind,fill_index[12:0]} : cache_read_addr0;
        xpm_memory_tdpram #(
            .MEMORY_SIZE(1048576),.MEMORY_PRIMITIVE("block"),
            .CLOCKING_MODE("common_clock"),.ECC_MODE("no_ecc"),
            .MEMORY_INIT_FILE("none"),.MEMORY_INIT_PARAM("0"),
            .USE_MEM_INIT(0),.USE_MEM_INIT_MMI(0),
            .MEMORY_OPTIMIZATION("true"),.CASCADE_HEIGHT(0),
            .AUTO_SLEEP_TIME(0),.WAKEUP_TIME("disable_sleep"),
            .MESSAGE_CONTROL(1),.SIM_ASSERT_CHK(1),.USE_EMBEDDED_CONSTRAINT(0),
            .ADDR_WIDTH_A(14),.ADDR_WIDTH_B(14),
            .WRITE_DATA_WIDTH_A(64),.READ_DATA_WIDTH_A(64),.BYTE_WRITE_WIDTH_A(64),
            .WRITE_DATA_WIDTH_B(64),.READ_DATA_WIDTH_B(64),.BYTE_WRITE_WIDTH_B(64),
            .READ_LATENCY_A(1),.READ_LATENCY_B(1),
            .READ_RESET_VALUE_A("0"),.READ_RESET_VALUE_B("0"),
            .RST_MODE_A("SYNC"),.RST_MODE_B("SYNC"),
            // No output is consumed during a write. NO_CHANGE also preserves
            // y0 while filling; B is disabled for every fill cycle. There is
            // no legal cross-port read/write collision to depend upon.
            .WRITE_MODE_A("no_change"),.WRITE_MODE_B("no_change")
        ) u_table (
            .clka(clk),.rsta(1'b0),.ena(memory_write||cache_read),.regcea(1'b1),
            .wea(memory_write),.addra(address_a),.dina(scalar_rsp_rdata),.douta(cache_y0),
            .injectsbiterra(1'b0),.injectdbiterra(1'b0),.sbiterra(),.dbiterra(),
            .clkb(clk),.rstb(1'b0),.enb(cache_read),.regceb(1'b1),
            .web(1'b0),.addrb(cache_read_addr1),.dinb(64'd0),.doutb(cache_y1),
            .injectsbiterrb(1'b0),.injectdbiterrb(1'b0),.sbiterrb(),.dbiterrb(),.sleep(1'b0)
        );
    end else begin:g_inferred_cache
        // Original inference template, retained as the default fallback.
        (* ram_style="block" *) reg signed [63:0] table_cache[0:16383];
        reg signed [63:0] y0_q,y1_q;
        always @(posedge clk) begin
            if (cache_write && !fill_index[13]) table_cache[{fill_kind,fill_index[12:0]}]<=scalar_rsp_rdata;
            else if (cache_read) y0_q<=table_cache[cache_read_addr0];
        end
        always @(posedge clk) begin
            if (cache_read) y1_q<=table_cache[cache_read_addr1];
        end
        assign cache_y0=y0_q;assign cache_y1=y1_q;
    end endgenerate
    // synthesis translate_off
    always @(posedge clk)if(rst_n)begin
        if(cache_write && cache_read)$fatal(1,"LUT fill/read ownership collision");
        if(cache_read && fill_mode)$fatal(1,"LUT lookup during cache fill");
        if(cache_write && !stream_idle)$fatal(1,"LUT fill before stream results drained");
    end
    // synthesis translate_on
    // Entry 8192 is the interpolation endpoint for the largest 13-bit
    // lookup index. Keep these two words in registers, avoiding two mostly
    // empty extra RAM banks. No lookup uses them before a successful fill.
    always @(posedge clk) begin
        if (cache_write && fill_index[13]) begin
            if (fill_kind) exp_endpoint<=scalar_rsp_rdata;
            else sigmoid_endpoint<=scalar_rsp_rdata;
        end
    end
    // The two elastic stages use the existing two RAM ports. Configuration
    // and legacy lookups cannot take ownership until both stages retire.
    always @(posedge clk) begin
        if (!rst_n) begin
            stream_stage_valid<=0;stream_rsp_valid<=0;
            stream_rsp_y0<=0;stream_rsp_y1<=0;stream_rsp_fault<=0;
        end else begin
            if (stream_stage_ready) begin
                stream_stage_valid<=stream_fire;
                if (stream_fire) begin
                    stream_endpoint<=&stream_req_index;
                    stream_kind<=stream_req_kind[0];
                    stream_fault<=(stream_req_kind>1 ||
                        {19'd0,stream_req_index}+32'd1 >=
                        (stream_req_kind[0] ? exp_entries_q : sigmoid_entries_q)) ? 4'd1 : 4'd0;
                end
            end
            if (stream_output_ready) begin
                stream_rsp_valid<=stream_stage_valid;
                if (stream_stage_valid) begin
                    stream_rsp_y0<=cache_y0;
                    stream_rsp_y1<=stream_endpoint ? (stream_kind ? exp_endpoint : sigmoid_endpoint) : cache_y1;
                    stream_rsp_fault<=stream_fault;
                end
            end
        end
    end

    // 36 bits cover an arbitrary 32-bit count times eight, plus base, without
    // truncating an overflowing descriptor before it can be rejected.
    function automatic [3:0] descriptor_fault;
        input [31:0] table_base;
        input [31:0] table_entries;
        input [2:0] table_dtype;
        input [31:0] region_base;
        input [31:0] region_bytes;
        reg [35:0] region_end, table_bytes, table_end;
        reg [3:0] faults;
        begin
            region_end = {4'd0, region_base} + {4'd0, region_bytes};
            table_bytes = {4'd0, table_entries} <<
                          ((table_dtype == DTYPE_I64) ? 3 : 2);
            table_end = {4'd0, table_base} + table_bytes;
            faults = 4'd0;
            if ((table_entries < 32'd2) ||
                ((table_dtype != DTYPE_I32) && (table_dtype != DTYPE_I64)))
                faults[FAULT_DESCRIPTOR] = 1'b1;
            if (((table_dtype == DTYPE_I32) && (|table_base[1:0])) ||
                ((table_dtype == DTYPE_I64) && (|table_base[2:0])))
                faults[FAULT_ALIGNMENT] = 1'b1;
            // End addresses are exclusive: exactly 2^32 is permitted.
            if ((region_bytes == 32'd0) ||
                (region_end > 36'd4294967296) ||
                (table_end > 36'd4294967296) ||
                ({4'd0, table_base} < {4'd0, region_base}) ||
                (table_end > region_end))
                faults[FAULT_BOUNDS] = 1'b1;
            descriptor_fault = faults;
        end
    endfunction

    wire [3:0] config_fault =
        descriptor_fault(sigmoid_base_pending, sigmoid_entries_pending, sigmoid_dtype_pending,
                         const_base_pending, const_bytes_pending) |
        descriptor_fault(exp_base_pending, exp_entries_pending, exp_dtype_pending,
                         const_base_pending, const_bytes_pending);
    wire selected_i64 = (lookup_dtype_q == DTYPE_I64);
    wire [1:0] selected_size = selected_i64 ? 2'd3 : 2'd2;
    wire [35:0] entry_bytes = selected_i64 ? 36'd8 : 36'd4;
    wire [35:0] pair_bytes = selected_i64 ? 36'd16 : 36'd8;

    always @* begin
        selected_base = 32'd0;
        selected_entries = 32'd0;
        selected_dtype = 3'd0;
        case (kind_q)
            LUT_SIGMOID: begin
                selected_base = sigmoid_base_q;
                selected_entries = sigmoid_entries_q;
                selected_dtype = sigmoid_dtype_q;
            end
            LUT_EXP: begin
                selected_base = exp_base_q;
                selected_entries = exp_entries_q;
                selected_dtype = exp_dtype_q;
            end
            default: begin
                selected_base = 32'd0;
                selected_entries = 32'd0;
                selected_dtype = 3'd0;
            end
        endcase
    end

    always @* begin
        // All sums have already been registered at full precision. Keep the
        // descriptor checks identical to descriptor_fault, while avoiding
        // another arithmetic chain in front of the fault decision.
        lookup_fault = 4'd0;
        if ((lookup_entries_q < 32'd2) ||
            ((lookup_dtype_q != DTYPE_I32) && (lookup_dtype_q != DTYPE_I64)))
            lookup_fault[FAULT_DESCRIPTOR] = 1'b1;
        if (((lookup_dtype_q == DTYPE_I32) && (|lookup_base_q[1:0])) ||
            ((lookup_dtype_q == DTYPE_I64) && (|lookup_base_q[2:0])))
            lookup_fault[FAULT_ALIGNMENT] = 1'b1;
        if ((const_bytes_q == 32'd0) ||
            (region_end_q > 36'd4294967296) ||
            (table_end_q > 36'd4294967296) ||
            ({4'd0, lookup_base_q} < {4'd0, const_base_q}) ||
            (table_end_q > region_end_q))
            lookup_fault[FAULT_BOUNDS] = 1'b1;
        if (!configured_q || kind_q > LUT_EXP ||
            ({18'd0, successor_index_q} >= lookup_entries_q))
            lookup_fault[FAULT_DESCRIPTOR] = 1'b1;
        if (((lookup_dtype_q == DTYPE_I32) &&
             ((|address0_wide_q[1:0]) || (|address1_wide_q[1:0]))) ||
            ((lookup_dtype_q == DTYPE_I64) &&
             ((|address0_wide_q[2:0]) || (|address1_wide_q[2:0]))))
            lookup_fault[FAULT_ALIGNMENT] = 1'b1;
        if ((address0_wide_q > 36'd4294967295) ||
            (address1_wide_q > 36'd4294967295) ||
            (pair_end_q > 36'd4294967296) ||
            (address0_wide_q < {4'd0, const_base_q}) ||
            (pair_end_q > region_end_q) ||
            (address0_wide_q < {4'd0, lookup_base_q}) ||
            (pair_end_q > table_end_q))
            lookup_fault[FAULT_BOUNDS] = 1'b1;
    end

    // Configuration wins if both producers present work in an idle cycle.
    assign config_ready = rst_n && (state == IDLE) && stream_idle;
    assign req_ready = rst_n && (state == IDLE) && !config_valid && stream_idle;
    assign config_rsp_valid = rst_n && (state == CONFIG_REPLY);
    assign rsp_valid = rst_n && (state == LOOKUP_REPLY);

    assign scalar_req_valid = rst_n &&
                              ((state == READ0_SEND) || (state == READ1_SEND));
    assign scalar_req_write = 1'b0;
    assign scalar_req_addr = (state == READ1_SEND) ? address1_q : address0_q;
    assign scalar_req_size = scalar_size_q;
    assign scalar_req_wdata = 64'd0;
    assign scalar_rsp_ready = rst_n &&
                              ((state == READ0_WAIT) || (state == READ1_WAIT));

    // Capture inputs on the handshake before checking their ranges. The
    // producer may change them immediately afterwards. No payload reset is
    // needed: reset returns to IDLE, and CONFIG_CHECK follows a full capture.
    always @(posedge clk) begin
        if (rst_n && config_valid && config_ready) begin
            const_base_pending <= const_base;
            const_bytes_pending <= const_bytes;
            sigmoid_base_pending <= sigmoid_base;
            sigmoid_entries_pending <= sigmoid_entries;
            sigmoid_dtype_pending <= sigmoid_dtype;
            exp_base_pending <= exp_base;
            exp_entries_pending <= exp_entries;
            exp_dtype_pending <= exp_dtype;
        end
    end

    // Each arithmetic stage contains independent single additions. In
    // particular, pair_end is formed directly from address0, rather than
    // cascading the address1 and end-address additions in one cycle.
    always @(posedge clk) begin
        if (rst_n) begin
            case (state)
                SELECT_LOOKUP: begin
                    lookup_base_q <= selected_base;
                    lookup_entries_q <= selected_entries;
                    lookup_dtype_q <= selected_dtype;
                end
                CALC_LOOKUP: begin
                    successor_index_q <= {1'b0, index_q} + 14'd1;
                    region_end_q <= {4'd0, const_base_q} + {4'd0, const_bytes_q};
                    table_end_q <= {4'd0, lookup_base_q} +
                        ({4'd0, lookup_entries_q} << (selected_i64 ? 3 : 2));
                    address0_wide_q <= {4'd0, lookup_base_q} +
                        ({23'd0, index_q} << (selected_i64 ? 3 : 2));
                end
                PAIR_LOOKUP: begin
                    address1_wide_q <= address0_wide_q + entry_bytes;
                    pair_end_q <= address0_wide_q + pair_bytes;
                end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            cache_valid<=0; fill_mode<=0; fill_complete<=0; fill_kind<=0; fill_index<=0;

            configured_q <= 1'b0;
            const_base_q <= 32'd0;
            const_bytes_q <= 32'd0;
            sigmoid_base_q <= 32'd0;
            sigmoid_entries_q <= 32'd0;
            sigmoid_dtype_q <= 3'd0;
            exp_base_q <= 32'd0;
            exp_entries_q <= 32'd0;
            exp_dtype_q <= 3'd0;
            kind_q <= 2'd0;
            index_q <= 13'd0;
            address0_q <= 32'd0;
            address1_q <= 32'd0;
            scalar_size_q <= 2'd2;
            config_rsp_fault <= 4'd0;
            rsp_y0 <= 64'sd0;
            rsp_y1 <= 64'sd0;
            rsp_fault <= 4'd0;
        end else begin
            case (state)
                IDLE: begin
                    if (config_valid && config_ready) begin
                        fill_complete<=0; state <= CONFIG_CHECK;
                    end else if (req_valid && req_ready) begin
                        kind_q <= req_kind;
                        index_q <= req_index;
                        rsp_y0 <= 64'sd0;
                        rsp_y1 <= 64'sd0;
                        rsp_fault <= 4'd0;
                        state <= SELECT_LOOKUP;
                    end
                end

                CONFIG_CHECK: begin
                    // End-address arithmetic and comparisons end at this
                    // fault register instead of driving all descriptor CEs.
                    config_rsp_fault <= config_fault;
                    state <= CONFIG_COMMIT;
                end

                CONFIG_COMMIT: begin
                    if (config_rsp_fault!=0) state<=CONFIG_REPLY;
                    else if (cache_eligible && !fill_complete) begin
                        // Descriptors stay uncommitted until both tables load.
                        cache_valid<=0; fill_mode<=1; fill_kind<=0; fill_index<=0;
                        address0_q<=sigmoid_base_pending;
                        scalar_size_q<=sigmoid_dtype_pending==DTYPE_I64 ? 2'd3 : 2'd2;
                        state<=READ0_SEND;
                    end else begin
                        configured_q<=1;
                        const_base_q<=const_base_pending; const_bytes_q<=const_bytes_pending;
                        sigmoid_base_q<=sigmoid_base_pending; sigmoid_entries_q<=sigmoid_entries_pending;
                        sigmoid_dtype_q<=sigmoid_dtype_pending;
                        exp_base_q<=exp_base_pending; exp_entries_q<=exp_entries_pending;
                        exp_dtype_q<=exp_dtype_pending;
                        cache_valid<=cache_eligible && fill_complete; fill_complete<=0;
                        state<=CONFIG_REPLY;
                    end
                end

                CONFIG_REPLY: begin
                    if (config_rsp_ready)
                        state <= IDLE;
                end

                SELECT_LOOKUP: state <= CALC_LOOKUP;

                CALC_LOOKUP: state <= PAIR_LOOKUP;

                PAIR_LOOKUP: state <= CHECK_LOOKUP;

                CHECK_LOOKUP: begin
                    rsp_fault <= lookup_fault;
                    state <= COMMIT_LOOKUP;
                end

                COMMIT_LOOKUP: begin
                    // The registered fault alone controls the scalar port
                    // and output-address CEs; no range logic reaches them.
                    if (rsp_fault != 4'd0) begin
                        state <= LOOKUP_REPLY;
                    end else begin
                        address0_q <= address0_wide_q[31:0];
                        address1_q <= address1_wide_q[31:0];
                        scalar_size_q <= selected_size;
                        state <= cache_valid ? CACHE_REPLY : READ0_SEND;
                    end
                end

                CACHE_REPLY: begin
                    rsp_y0<=cache_y0;
                    rsp_y1<=index_q==13'h1fff ? (kind_q[0] ? exp_endpoint : sigmoid_endpoint) : cache_y1;
                    state<=LOOKUP_REPLY;
                end

                READ0_SEND: begin
                    if (scalar_req_valid && scalar_req_ready)
                        state <= READ0_WAIT;
                end

                READ0_WAIT: begin
                    if (scalar_rsp_valid && scalar_rsp_ready) begin
                        if (fill_mode) begin
                            if (scalar_rsp_fault!=0) begin
                                config_rsp_fault<=4'b1000; fill_mode<=0; state<=CONFIG_REPLY;
                            end else if ({18'd0,fill_index}+32'd1 == (fill_kind ? exp_entries_pending : sigmoid_entries_pending)) begin
                                if (fill_kind) begin
                                    fill_mode<=0; fill_complete<=1; state<=CONFIG_COMMIT;
                                end else begin
                                    fill_kind<=1; fill_index<=0; address0_q<=exp_base_pending;
                                    scalar_size_q<=exp_dtype_pending==DTYPE_I64 ? 2'd3 : 2'd2;
                                    state<=READ0_SEND;
                                end
                            end else begin
                                fill_index<=fill_index+1'b1;
                                address0_q<=address0_q+(scalar_size_q==3 ? 32'd8 : 32'd4);
                                state<=READ0_SEND;
                            end
                        end else if (scalar_rsp_fault != 4'd0) begin
                            rsp_fault[FAULT_SCALAR] <= 1'b1;
                            rsp_y0 <= 64'sd0;
                            rsp_y1 <= 64'sd0;
                            state <= LOOKUP_REPLY;
                        end else begin
                            rsp_y0 <= scalar_rsp_rdata;
                            state <= READ1_SEND;
                        end
                    end
                end

                READ1_SEND: begin
                    if (scalar_req_valid && scalar_req_ready)
                        state <= READ1_WAIT;
                end

                READ1_WAIT: begin
                    if (scalar_rsp_valid && scalar_rsp_ready) begin
                        if (scalar_rsp_fault != 4'd0) begin
                            rsp_fault[FAULT_SCALAR] <= 1'b1;
                            rsp_y0 <= 64'sd0;
                            rsp_y1 <= 64'sd0;
                        end else begin
                            rsp_y1 <= scalar_rsp_rdata;
                        end
                        state <= LOOKUP_REPLY;
                    end
                end

                LOOKUP_REPLY: begin
                    // No descriptor or response changes until retirement.
                    if (rsp_ready)
                        state <= IDLE;
                end

                default: begin
                    // Do not declare the shared scalar port free after an
                    // invalid internal encoding; shared reset is required.
                    state <= state;
                end
            endcase
        end
    end
endmodule

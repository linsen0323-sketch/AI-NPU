`timescale 1ns/1ps
// 8 input channels x 32 logical output channels. PHYSICAL_OUTPUTS selects
// how many lanes execute concurrently; the remaining groups reuse them.
// act[i*16+:16] is signed A16; A8 uses its low signed byte.
// weight[(o*8+i)*8+:8] is signed W8. A8 accepts one vector per GROUPS
// cycles; A16 takes 2*GROUPS cycles and exactly reconstructs
// x16*w8 = unsigned(x16[7:0])*w8 + (signed(x16[15:8])*w8 << 8).
// 32 independent ACC_W-bit accumulators. in_first starts a dot product;
// in_last publishes its accumulated result. No output backpressure.
// Production P256 selects PHYSICAL_OUTPUTS=32, DSP_PACKING=1: 128 packed
// DSPs execute 256 A8*W8 products per issue, one issue/cycle. A16 needs two
// byte phases, giving 128 complete A16*W8 products/cycle averaged over them.
// DSP_PACKING=0 retains the independent-multiplier implementation as an option.
// Reset asserts interface masking immediately. After release the array is
// busy/not-ready for two recovery clocks; normal accepted-vector latency and
// A8/A16 issue intervals are unchanged once in_ready is available.
module npu_pe_8x32 #(
    parameter integer ACC_W = 64,
    parameter integer PHYSICAL_OUTPUTS = 32,
    parameter bit DSP_PACKING = 1'b1,
    parameter bit ENABLE_PE_SPATIAL4 = 1'b0,
    parameter bit ENABLE_WEIGHT_PRELOAD = 1'b0,
    parameter bit FACTOR_PARTIAL_VALID = 1'b0,
    parameter bit QUALIFIED_ACC_OUTPUT = 1'b0,
 parameter bit SHARED_WEIGHT_SELECT=1'b0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    output logic in_ready,
    input  logic in_a16,
    input  logic in_first,
    input  logic in_last,
    input  logic [127:0] act,
    input  logic in_spatial4,
    input  logic [511:0] act4,
    input  logic [2047:0] weight,
    output logic busy,
    output logic out_valid,
    output logic [2047:0] acc,
    output logic overflow,
 input logic [1:0] weight_group
);
    localparam integer GROUPS = 32/PHYSICAL_OUTPUTS;
    localparam bit HOLD_DSP_WEIGHT = DSP_PACKING && GROUPS==1;
    localparam bit PRELOAD_EN = ENABLE_WEIGHT_PRELOAD && DSP_PACKING && GROUPS==1;
    localparam integer GROUP_W = GROUPS>1 ? $clog2(GROUPS) : 1;
    localparam integer PHASE_W = $clog2(GROUPS*2+1);
    // Capture even an inter-edge reset pulse in this small asynchronous
    // chain. All other PE control/validity state clears synchronously while
    // the chain is empty. Two recovery clocks precede any input acceptance,
    // so no admitted vector can subsequently be discarded by startup reset.
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] reset_ready;
    wire pe_ready = rst_n && reset_ready[1];
    logic out_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) reset_ready <= 2'b00;
        else reset_ready <= {reset_ready[0],1'b1};
    end
    logic phase_pending, saved_a16;
    logic [PHASE_W-1:0] phase_index;
    logic [127:0] saved_act;
    logic [511:0] saved_act4;
    logic saved_spatial4;
    logic [2047:0] saved_weight;
    logic saved_first, saved_last;
    // Optional control/operand-only optimization. One shared 512-bit bus
    // loads the existing native DSP A/D weight registers: all four spatial
    // groups together, or four legacy Cout groups successively. The DSP
    // primitive inference, product/reduction/accumulator arithmetic and real
    // MAC tag latency are unchanged. Preload products are unqualified and have no
    // array-valid tag, so they cannot modify a visible accumulation.
    logic [1:0] preload_index;
    logic preload_complete;
    wire preload_spatial = ENABLE_PE_SPATIAL4 && in_spatial4;
    wire preload_fire = PRELOAD_EN && pe_ready && !phase_pending &&
                        in_valid && !preload_complete;
    wire [1:0] preload_bus_group = preload_spatial ? (SHARED_WEIGHT_SELECT ? weight_group : 2'd0) : preload_index;
    wire [511:0] preload_weights = weight[{preload_bus_group,9'd0}+:512];
    wire preload_busy = PRELOAD_EN &&
                        (preload_fire || preload_complete || preload_index!=0);
    always_ff @(posedge clk)begin
        if(!pe_ready)begin preload_index<=0;preload_complete<=0;end
        else if(PRELOAD_EN)begin
            if(!in_valid || (in_valid&&in_ready))begin
                preload_index<=0;preload_complete<=0;
            end else if(preload_fire)begin
                if(preload_spatial || preload_index==3)begin
                    preload_index<=0;preload_complete<=1;
                end else preload_index<=preload_index+1'b1;
            end
        end
    end
    wire accept = in_valid && in_ready;
    wire issue_valid = pe_ready && (phase_pending || accept);
    wire issue_a16 = phase_pending ? saved_a16 : in_a16;
    wire issue_high = phase_pending && saved_a16 && phase_index[0];
    // A single physical group always targets context zero, including A16's high phase.
    wire [GROUP_W-1:0] issue_group = GROUPS==1 ? '0 : (phase_pending ?
        GROUP_W'(phase_index >> (saved_a16 ? 1 : 0)) : '0);
    wire issue_first = phase_pending ? saved_first : in_first;
    wire issue_last = phase_pending ? saved_last : in_last;
    // One packed group retains A16 weights in the DSP input registers.
    wire [1:0] live_weight_group=SHARED_WEIGHT_SELECT && ENABLE_PE_SPATIAL4 &&
        PHYSICAL_OUTPUTS==32 && in_spatial4 ? weight_group : 2'd0;
    wire [2047:0] prepared_weight={weight[2047:512],weight[{live_weight_group,9'd0}+:512]};
    wire [PHYSICAL_OUTPUTS*64-1:0] issue_weight = HOLD_DSP_WEIGHT ?
        prepared_weight[0+:PHYSICAL_OUTPUTS*64] : phase_pending ?
        saved_weight[int'(issue_group)*PHYSICAL_OUTPUTS*64+:PHYSICAL_OUTPUTS*64] :
        prepared_weight[0+:PHYSICAL_OUTPUTS*64];
    wire [127:0] issue_act = phase_pending ? saved_act : act;
    wire issue_spatial4 = ENABLE_PE_SPATIAL4 && PHYSICAL_OUTPUTS==32 &&
        (phase_pending ? saved_spatial4 : in_spatial4);
    wire [511:0] issue_act4 = phase_pending ? saved_act4 : act4;
    logic signed [8:0] issue_x [0:3][0:7];
    logic [2:0] valid_pipe, a16_pipe, high_pipe, first_pipe, last_pipe;
    logic signed [15:0] pair_p [0:PHYSICAL_OUTPUTS-1][0:7];
    logic [PHYSICAL_OUTPUTS*4-1:0] pair_valid;
    logic [GROUP_W-1:0] group_pipe[0:2], tree_group[0:2];
    logic [GROUP_W-1:0] corrected_group, recon_group;
    logic recon_valid, recon_first, recon_last;
    logic [2:0] tree_valid, tree_first, tree_last, tree_a16, tree_high;
    logic corrected_valid,corrected_first,corrected_last,corrected_a16,corrected_high;
    // Reduce byte products before A16 reconstruction. Linearity permits one
    // reconstruction adder per output, instead of one per individual product.
    (* use_dsp = "no" *) logic signed [16:0] sum2 [0:PHYSICAL_OUTPUTS-1][0:3];
    (* use_dsp = "no" *) logic signed [17:0] sum4 [0:PHYSICAL_OUTPUTS-1][0:1];
    (* use_dsp = "no" *) logic signed [18:0] sum8 [0:PHYSICAL_OUTPUTS-1];
    (* use_dsp = "no" *) logic signed [18:0] corrected_sum [0:PHYSICAL_OUTPUTS-1];
    (* use_dsp = "no" *) logic signed [ACC_W:0] partial_sum [0:PHYSICAL_OUTPUTS-1];
    // The standalone contract defaults to INT64. The integrated convolution
    // client limits a dot to K<=1024; A16*W8 then needs at most 34 signed bits.
    // Its 40-bit configuration keeps headroom without 32 unused upper adders.
    (* use_dsp = "no" *) logic signed [ACC_W-1:0] accumulator [0:31];
    wire signed [ACC_W-1:0] visible_accumulator [0:31];
    logic [31:0] lane_overflow;

    assign in_ready = pe_ready && !phase_pending && (!PRELOAD_EN || preload_complete);
    assign out_valid = pe_ready && out_valid_q;
    // Hold the wrapper non-idle during synchronous recovery. Reset assertion
    // itself masks the external interface immediately, including short pulses.
    assign busy = rst_n && (!reset_ready[1] || phase_pending || preload_busy || (|valid_pipe) ||
                  recon_valid || (|tree_valid) || corrected_valid || out_valid_q);
    assign overflow = pe_ready && (|lane_overflow);
    always_ff @(posedge clk) begin
        if (!pe_ready) begin
            phase_pending <= 1'b0;
            phase_index <= '0;
            valid_pipe <= '0; a16_pipe <= '0; high_pipe <= '0;
            first_pipe <= '0; last_pipe <= '0;
            recon_valid <= 1'b0; recon_first <= 1'b0; recon_last <= 1'b0;
            tree_valid <= '0; tree_first <= '0; tree_last <= '0;
            tree_a16 <= '0; tree_high <= '0;
            corrected_valid<=0;corrected_first<=0;corrected_last<=0;
            corrected_a16<=0;corrected_high<=0;
            out_valid_q <= 1'b0;
        end else begin
            if (phase_pending) begin
                if (phase_index == PHASE_W'((GROUPS << (saved_a16 ? 1 : 0))-1))
                    phase_pending <= 1'b0;
                else phase_index <= phase_index+1'b1;
            end else if (accept && (GROUPS>1 || in_a16)) begin
                phase_pending <= 1'b1;
                phase_index <= PHASE_W'(1);
            end
            valid_pipe <= {valid_pipe[1:0],issue_valid};
            a16_pipe <= {a16_pipe[1:0],issue_a16};
            high_pipe <= {high_pipe[1:0],issue_high};
            first_pipe <= {first_pipe[1:0],issue_first};
            last_pipe <= {last_pipe[1:0],issue_last};
            tree_valid <= {tree_valid[1:0],valid_pipe[2]};
            tree_first <= {tree_first[1:0],first_pipe[2]};
            tree_last <= {tree_last[1:0],last_pipe[2]};
            tree_a16 <= {tree_a16[1:0],a16_pipe[2]};
            tree_high <= {tree_high[1:0],high_pipe[2]};
            corrected_valid<=tree_valid[2];corrected_first<=tree_first[2];
            corrected_last<=tree_last[2];corrected_a16<=tree_a16[2];corrected_high<=tree_high[2];
            recon_valid <= corrected_valid && (!corrected_a16 || corrected_high);
            recon_first <= corrected_first;
            recon_last <= corrected_last;
            out_valid_q <= recon_valid && recon_last &&
                         (GROUPS==1 || recon_group==GROUP_W'(GROUPS-1));
        end
    end
    always_ff @(posedge clk) begin
        if (accept && (GROUPS>1 || in_a16)) begin
            saved_act <= act;
            if (ENABLE_PE_SPATIAL4) begin
                saved_act4 <= act4;
                saved_spatial4 <= in_spatial4;
            end
            saved_weight <= prepared_weight;
            saved_first <= in_first;
            saved_last <= in_last;
            saved_a16 <= in_a16;
        end
        group_pipe[0]<=issue_group;
        group_pipe[1]<=group_pipe[0];group_pipe[2]<=group_pipe[1];
        tree_group[0]<=group_pipe[2];tree_group[1]<=tree_group[0];tree_group[2]<=tree_group[1];
        corrected_group<=tree_group[2];recon_group<=corrected_group;
    end
    genvar i,p,o,j;
    generate
        for (genvar space=0;space<4;space=space+1) begin : g_space_activation
        for (i=0;i<8;i=i+1) begin : g_x
            wire [15:0] x16 = issue_spatial4 ? issue_act4[space*128+i*16+:16] : issue_act[i*16+:16];
            always_comb begin
                if (issue_high)
                    issue_x[space][i] = {x16[15],x16[15:8]};
                else if (issue_a16)
                    issue_x[space][i] = {1'b0,x16[7:0]};
                else
                    issue_x[space][i] = {x16[7],x16[7:0]};
            end
        end end
        for (p=0;p<PHYSICAL_OUTPUTS/2;p=p+1) begin : g_pair
            // Four groups of four output pairs: 4 * (8Cin * 8Cout).
            // Every pair still shares ONE activation; no DSP pairs spaces.
            localparam integer SPACE = p/4;
            for (i=0;i<8;i=i+1) begin : g_input
                wire [7:0] w0 = issue_spatial4 ? issue_weight[((2*p)%8*8+i)*8+:8] :
                    issue_weight[((2*p)*8+i)*8+:8];
                wire [7:0] w1 = issue_spatial4 ? issue_weight[(((2*p+1)%8)*8+i)*8+:8] :
                    issue_weight[((2*p+1)*8+i)*8+:8];
                if (DSP_PACKING) begin : g_packed
                wire pair_preload = preload_fire &&
                    (preload_spatial || preload_index==SPACE);
                wire [7:0] load_w0 = PRELOAD_EN ?
                    preload_weights[(((2*p)%8)*8+i)*8+:8] : w0;
                wire [7:0] load_w1 = PRELOAD_EN ?
                    preload_weights[(((2*p+1)%8)*8+i)*8+:8] : w1;
                npu_dsp48_pair #(.CORRECT_HIGH(1'b0)) u_dsp (
                    .clk(clk),.rst_n(rst_n),.in_valid(issue_valid||pair_preload),
                    .weight_load(PRELOAD_EN ? pair_preload : (GROUPS==1 ? accept : 1'b1)),
                    .x(issue_x[SPACE][i]),.w0(load_w0),.w1(load_w1),
                    .out_valid(pair_valid[p*8+i]),
                    .p0(pair_p[2*p][i]),.p1(pair_p[2*p+1][i])
                );
                end else begin : g_direct
                    // Same E+2 product latency as the packed pair. Two native
                    // multipliers trade spare DSPs for the packing pre-adder,
                    // sign-extension and upper-lane correction LUTs.
                    logic signed [8:0] x_q;
                    logic signed [7:0] w0_q,w1_q;
                    (* use_dsp="yes" *) logic signed [16:0] m0,m1;
                    always_ff @(posedge clk) begin
                        if(issue_valid) begin
                            x_q<=issue_x[SPACE][i];
                            w0_q<=w0;w1_q<=w1;
                        end
                        if(valid_pipe[0]) begin m0<=x_q*w0_q;m1<=x_q*w1_q;end
                        if(valid_pipe[1]) begin
                            pair_p[2*p][i]<=m0[15:0];
                            pair_p[2*p+1][i]<=m1[15:0];
                        end
                    end
                    assign pair_valid[p*8+i]=valid_pipe[2];
                end
            end
        end
        for (o=0;o<PHYSICAL_OUTPUTS;o=o+1) begin : g_output
            // Valid tags qualify consumption; pure pipeline data needs no CE.
            wire [3:0] correction8;
            if(DSP_PACKING && (o%2)==1) begin : g_upper_correction
                logic [1:0] correction2[0:3];
                logic [2:0] correction4[0:1];
                logic [3:0] correction_q;
                for(genvar c=0;c<4;c=c+1) begin : g_two
                    always_ff @(posedge clk)
                        correction2[c]<=
                            {1'b0,pair_p[o-1][2*c][15]}+{1'b0,pair_p[o-1][2*c+1][15]};
                end
                for(genvar c=0;c<2;c=c+1) begin : g_four
                    always_ff @(posedge clk)
                        correction4[c]<=
                            {1'b0,correction2[2*c]}+{1'b0,correction2[2*c+1]};
                end
                always_ff @(posedge clk)
                    correction_q<=
                        {1'b0,correction4[0]}+{1'b0,correction4[1]};
                assign correction8=correction_q;
            end else begin : g_lower_correction
                assign correction8=4'd0;
            end
            for (j=0;j<4;j=j+1) begin : g_sum2
                always_ff @(posedge clk)
                    sum2[o][j] <= $signed({pair_p[o][2*j][15],pair_p[o][2*j]}) +
                                      $signed({pair_p[o][2*j+1][15],pair_p[o][2*j+1]});
            end
            for (j=0;j<2;j=j+1) begin : g_sum4
                always_ff @(posedge clk)
                    sum4[o][j] <= $signed({sum2[o][2*j][16],sum2[o][2*j]}) +
                                      $signed({sum2[o][2*j+1][16],sum2[o][2*j+1]});
            end
            always_ff @(posedge clk)
                sum8[o] <= $signed({sum4[o][0][17],sum4[o][0]}) +
                               $signed({sum4[o][1][17],sum4[o][1]});
            // One correction adder per odd output replaces eight per-product
            // incrementers. A separate stage keeps correction out of the A16
            // reconstruction carry chain. Throughput is unchanged; latency +1.
            always_ff @(posedge clk)
                corrected_sum[o]<=
                    sum8[o]+$signed({15'd0,correction8});
            wire signed [ACC_W:0] visible_partial;
            wire signed [ACC_W-1:0] selected_acc = GROUPS==1 ? visible_accumulator[o] :
                visible_accumulator[int'(corrected_group)*PHYSICAL_OUTPUTS+o];
            // A16's adjacent byte phases share the accumulation adder. Keep
            // one guard bit until the high phase, so a low-phase overflow
            // that the high phase cancels does not become a sticky overflow.
            // The preceding completed vector commits on this same edge;
            // forward its wrapped result when the next vector uses its lane.
            wire forward_acc = recon_valid &&
                (GROUPS==1 || recon_group==corrected_group);
            wire continue_high = corrected_a16 && corrected_high;
            wire partial_visible;
            // Exact control factoring, including cold non-first/reset states:
            // clear ? 0 : (valid ? p : 0) == (clear || !valid) ? 0 : p.
            // No adder, product, accumulator width, tag or latency is changed.
            wire clear_sum = (corrected_first && !continue_high) ||
                (FACTOR_PARTIAL_VALID && GROUPS==1 && !partial_visible);
            wire use_partial = continue_high || forward_acc;
            wire signed [ACC_W-1:0] base_acc = GROUPS==1 || use_partial ?
                visible_partial[ACC_W-1:0] : selected_acc;
            wire base_guard = continue_high ? visible_partial[ACC_W] : base_acc[ACC_W-1];
            wire signed [ACC_W:0] add_base = clear_sum ? '0 : $signed({base_guard,base_acc});
            wire signed [ACC_W:0] add_term = corrected_a16 && corrected_high ?
                $signed({{(ACC_W-26){corrected_sum[o][18]}},corrected_sum[o],8'b0}) :
                $signed({{(ACC_W-18){corrected_sum[o][18]}},corrected_sum[o]});
            if (GROUPS==1) begin:g_single_partial
                // With one context this register also retains the most
                // recent accumulator, including through idle cycles. Reset
                // only a local validity bit, keeping CLR off the wide data.
                logic initialized;
                // Preserve one local visibility gate per lane rather than
                // broadcasting pe_ready through every bit of a wide mux.
                wire visible_initialized = initialized && pe_ready;
                assign partial_visible = visible_initialized;
                assign visible_partial = FACTOR_PARTIAL_VALID ? partial_sum[o] :
                    visible_initialized ? partial_sum[o] : '0;
                always_ff @(posedge clk)
                    if (!pe_ready) initialized <= 1'b0;
                    else if (corrected_valid) initialized <= 1'b1;
                always_ff @(posedge clk)
                    if (corrected_valid) partial_sum[o] <= add_base + add_term;
            end else begin:g_grouped_partial
                assign partial_visible = 1'b1;
                assign visible_partial = partial_sum[o];
                always_ff @(posedge clk)
                    if (corrected_valid) partial_sum[o] <= add_base + add_term;
            end
            for (genvar g=0;g<GROUPS;g=g+1) begin:g_context
                localparam integer LANE=g*PHYSICAL_OUTPUTS+o;
                wire commit = recon_valid && (GROUPS==1 || recon_group==GROUP_W'(g));
                if(QUALIFIED_ACC_OUTPUT)begin:g_qualified_result
                    // Only a wrapper that samples ACC on out_valid may opt in.
                    // The wrapper retains its reset/error result register.
                    // No execution/overflow/reset-valid control is removed.
                    assign visible_accumulator[LANE] = accumulator[LANE];
                end else begin:g_original_result_visibility
                    logic initialized;
                    wire visible_initialized = initialized && pe_ready;
                    assign visible_accumulator[LANE] = visible_initialized ? accumulator[LANE] : '0;
                    always_ff @(posedge clk)begin
                        if(!pe_ready) initialized<=1'b0;
                        else if(commit) initialized<=1'b1;
                    end
                end
                always_ff @(posedge clk)
                    if (commit) accumulator[LANE] <= partial_sum[o][ACC_W-1:0];
                always_ff @(posedge clk) begin
                    if (!pe_ready) begin
                        lane_overflow[LANE] <= 1'b0;
                    end else if (commit) begin
                        if (recon_first) lane_overflow[LANE] <= 1'b0;
                        else lane_overflow[LANE] <= lane_overflow[LANE] ||
                            (partial_sum[o][ACC_W] != partial_sum[o][ACC_W-1]);
                    end
                end
            end
        end
        for(genvar lane=0;lane<32;lane=lane+1) begin:g_result
            assign acc[lane*64+:64] = {{(64-ACC_W){visible_accumulator[lane][ACC_W-1]}},visible_accumulator[lane]};
        end
    endgenerate
    initial begin
        if (ACC_W<27 || ACC_W>64 || PHYSICAL_OUTPUTS<2 || PHYSICAL_OUTPUTS>32 ||
            PHYSICAL_OUTPUTS%2!=0 || 32%PHYSICAL_OUTPUTS!=0)
            $error("Unsupported packed PE accumulator width or physical lane count");
    end
endmodule

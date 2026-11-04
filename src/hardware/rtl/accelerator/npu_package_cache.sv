`timescale 1ns/1ps
// Word-serial fully associative verified-package metadata cache. The checked frontend is
// external; its memory channel is not routed through this wrapper.
// Cache hits are valid only under the generation/immutability contract in
// docs/package_cache.md. Invalidate is an idle-only global flush.
module npu_package_cache #(
    parameter integer ENTRIES = 3
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         cmd_valid,
    output logic         cmd_ready,
    input  logic [31:0]  cmd_model_base,
    input  logic [31:0]  cmd_model_capacity,
    input  logic [31:0]  cmd_workspace_base,
    input  logic [31:0]  cmd_workspace_capacity,
    input  logic [31:0]  cmd_generation,
    input  logic         cmd_allow_cache,
    input  logic         invalidate_valid,
    output logic         invalidate_ready,

    output logic         inner_cmd_valid,
    input  logic         inner_cmd_ready,
    output logic [31:0]  inner_cmd_model_base,
    output logic [31:0]  inner_cmd_model_capacity,
    output logic [31:0]  inner_cmd_workspace_base,
    output logic [31:0]  inner_cmd_workspace_capacity,
    input  logic         inner_rsp_valid,
    output logic         inner_rsp_ready,
    input  logic [3:0]   inner_rsp_fault,
    input  logic [31:0]  inner_rsp_model_id,
    input  logic [31:0]  inner_rsp_profile,
    input  logic [31:0]  inner_rsp_image_bytes,
    input  logic [31:0]  inner_rsp_workspace_bytes,
    input  logic [31:0]  inner_rsp_input_id,
    input  logic [31:0]  inner_rsp_output_id,
    input  logic [31:0]  inner_rsp_input_lut_id,
    input  logic [159:0] inner_rsp_section_addr,
    input  logic [159:0] inner_rsp_section_bytes,

    output logic         rsp_valid,
    input  logic         rsp_ready,
    output logic [3:0]   rsp_fault,
    output logic [31:0]  rsp_model_id,
    output logic [31:0]  rsp_profile,
    output logic [31:0]  rsp_image_bytes,
    output logic [31:0]  rsp_workspace_bytes,
    output logic [31:0]  rsp_input_id,
    output logic [31:0]  rsp_output_id,
    output logic [31:0]  rsp_input_lut_id,
    output logic [159:0] rsp_section_addr,
    output logic [159:0] rsp_section_bytes,
    output logic         cache_hit_pulse,
    output logic         busy
);
    localparam integer INDEX_BITS = ENTRIES<2 ? 1 : $clog2(ENTRIES);
    typedef struct packed {
        logic [31:0] model_base;
        logic [31:0] model_capacity;
        logic [31:0] workspace_base;
        logic [31:0] workspace_capacity;
        logic [31:0] generation;
    } key_t;
    typedef struct packed {
        logic [31:0] model_id;
        logic [31:0] profile;
        logic [31:0] image_bytes;
        logic [31:0] workspace_bytes;
        logic [31:0] input_id;
        logic [31:0] output_id;
        logic [31:0] input_lut_id;
        logic [159:0] section_addr;
        logic [159:0] section_bytes;
    } metadata_t;
    localparam integer KEY_WORDS=$bits(key_t)/32;
    localparam integer META_WORDS=$bits(metadata_t)/32;
    localparam integer ROW_WORDS=32;
    localparam integer RAM_ADDR_BITS=$clog2(ENTRIES*ROW_WORDS);
    typedef enum logic [3:0] {IDLE, KEY_REQUEST, KEY_VALUE, INNER_REQUEST,
        INNER_WAIT, META_REQUEST, META_VALUE, FILL, RESPONSE} state_t;
    state_t state;
    // Only valid bits reset. The payload has one synchronous read and one
    // synchronous write port, so it can map to one small block RAM rather
    // than a wide metadata register file and fully parallel return mux.
    (* ram_style="block" *) logic [31:0] cache_words[0:ENTRIES*ROW_WORDS-1];
    logic [ENTRIES-1:0] entry_valid;
    logic [31:0] ram_rdata,ram_wdata,key_word;
    logic ram_read,ram_write;
    logic [RAM_ADDR_BITS-1:0] ram_address;
    logic [INDEX_BITS-1:0] scan_entry;
    logic [4:0] word_index;
    key_t command_key, active_key;
    metadata_t inner_metadata, response_metadata;
    logic active_allow_cache;
    logic [INDEX_BITS-1:0] replacement_index, fill_index;
    logic empty_found;
    logic [INDEX_BITS-1:0] fill_choice;

    always_comb begin
        command_key.model_base = cmd_model_base;
        command_key.model_capacity = cmd_model_capacity;
        command_key.workspace_base = cmd_workspace_base;
        command_key.workspace_capacity = cmd_workspace_capacity;
        command_key.generation = cmd_generation;
        inner_metadata.model_id = inner_rsp_model_id;
        inner_metadata.profile = inner_rsp_profile;
        inner_metadata.image_bytes = inner_rsp_image_bytes;
        inner_metadata.workspace_bytes = inner_rsp_workspace_bytes;
        inner_metadata.input_id = inner_rsp_input_id;
        inner_metadata.output_id = inner_rsp_output_id;
        inner_metadata.input_lut_id = inner_rsp_input_lut_id;
        inner_metadata.section_addr = inner_rsp_section_addr;
        inner_metadata.section_bytes = inner_rsp_section_bytes;

        empty_found = 1'b0; fill_choice = replacement_index;
        for (integer c=0; c<ENTRIES; c=c+1) begin
            if (!empty_found && !entry_valid[c]) begin
                empty_found = 1'b1; fill_choice = INDEX_BITS'(c);
            end
        end
        key_word=32'd0;
        for(integer w=0;w<KEY_WORDS;w=w+1)
            key_word=key_word | (active_key[w*32+:32] & {32{word_index==5'(w)}});
        ram_read=rst_n && ((state==KEY_REQUEST && entry_valid[scan_entry]) || state==META_REQUEST);
        ram_write=rst_n && state==FILL;
        ram_address=(RAM_ADDR_BITS'(scan_entry)<<5)+RAM_ADDR_BITS'(word_index);
        if(state==META_REQUEST)
            ram_address=(RAM_ADDR_BITS'(scan_entry)<<5)+
                RAM_ADDR_BITS'(KEY_WORDS)+RAM_ADDR_BITS'(word_index);
        if(state==FILL)
            ram_address=(RAM_ADDR_BITS'(fill_index)<<5)+RAM_ADDR_BITS'(word_index);
        ram_wdata=32'd0;
        // Every word decode is distinct; expose the parallel one-hot mux.
        for(integer w=0;w<KEY_WORDS;w=w+1)
            ram_wdata=ram_wdata | (active_key[w*32+:32] & {32{word_index==5'(w)}});
        for(integer w=0;w<META_WORDS;w=w+1)
            ram_wdata=ram_wdata | (response_metadata[w*32+:32] &
                {32{word_index==5'(KEY_WORDS+w)}});
        // A pending invalidate wins over command admission only while idle.
        // It cannot cancel an admitted command or abandon frontend traffic.
        invalidate_ready = rst_n && state==IDLE;
        cmd_ready = rst_n && state==IDLE && !invalidate_valid;
        inner_cmd_valid = rst_n && state==INNER_REQUEST;
        inner_cmd_model_base = active_key.model_base;
        inner_cmd_model_capacity = active_key.model_capacity;
        inner_cmd_workspace_base = active_key.workspace_base;
        inner_cmd_workspace_capacity = active_key.workspace_capacity;
        inner_rsp_ready = rst_n && state==INNER_WAIT;
        rsp_valid = rst_n && state==RESPONSE;
        busy = state!=IDLE;
        rsp_model_id = response_metadata.model_id;
        rsp_profile = response_metadata.profile;
        rsp_image_bytes = response_metadata.image_bytes;
        rsp_workspace_bytes = response_metadata.workspace_bytes;
        rsp_input_id = response_metadata.input_id;
        rsp_output_id = response_metadata.output_id;
        rsp_input_lut_id = response_metadata.input_lut_id;
        rsp_section_addr = response_metadata.section_addr;
        rsp_section_bytes = response_metadata.section_bytes;
    end

    always_ff @(posedge clk) begin
        if(ram_write) cache_words[ram_address]<=ram_wdata;
        if(ram_read) ram_rdata<=cache_words[ram_address];
    end

    task automatic next_entry;
        begin
            word_index<=0;
            if(scan_entry==INDEX_BITS'(ENTRIES-1)) state<=INNER_REQUEST;
            else begin scan_entry<=scan_entry+1'b1;state<=KEY_REQUEST;end
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE; active_key <= '0; active_allow_cache <= 1'b0;
            response_metadata <= '0; rsp_fault <= '0;
            replacement_index <= '0; fill_index <= '0; cache_hit_pulse <= 1'b0;
            entry_valid<='0;scan_entry<='0;word_index<=0;
        end else begin
            cache_hit_pulse <= 1'b0;
            case (state)
                IDLE: begin
                    if (invalidate_valid) begin
                        entry_valid<='0;
                        replacement_index <= '0;
                    end else if (cmd_valid) begin
                        active_key <= command_key;
                        active_allow_cache <= cmd_allow_cache;
                        fill_index <= fill_choice;
                        rsp_fault <= '0;
                        scan_entry<=0;word_index<=0;state<=KEY_REQUEST;
                    end
                end
                KEY_REQUEST: begin
                    if(!entry_valid[scan_entry]) next_entry();
                    else state<=KEY_VALUE;
                end
                KEY_VALUE: begin
                    if(ram_rdata!=key_word) next_entry();
                    else if(word_index!=5'(KEY_WORDS-1)) begin
                        word_index<=word_index+1'b1;state<=KEY_REQUEST;
                    end else if(active_allow_cache) begin
                        word_index<=0;state<=META_REQUEST;
                    end else begin
                        // Forced validation scans and evicts every matching
                        // key before admitting its frontend command. A failed
                        // revalidation cannot resurrect a formerly valid row.
                        entry_valid[scan_entry]<=0;next_entry();
                    end
                end
                INNER_REQUEST: if (inner_cmd_ready) state <= INNER_WAIT;
                INNER_WAIT: if (inner_rsp_valid) begin
                    response_metadata <= inner_metadata;
                    rsp_fault <= inner_rsp_fault;
                    if (active_allow_cache && inner_rsp_fault==0) begin
                        // Evict before writing any word. Publish validity only
                        // after the final metadata word has reached RAM.
                        entry_valid[fill_index]<=0;word_index<=0;state<=FILL;
                    end else state <= RESPONSE;
                end
                META_REQUEST: state<=META_VALUE;
                META_VALUE: begin
                    for(integer w=0;w<META_WORDS;w=w+1)
                        if(word_index==5'(w)) response_metadata[w*32+:32]<=ram_rdata;
                    if(word_index==5'(META_WORDS-1)) begin
                        cache_hit_pulse<=1;state<=RESPONSE;
                    end else begin word_index<=word_index+1'b1;state<=META_REQUEST;end
                end
                FILL: begin
                    if(word_index==5'(KEY_WORDS+META_WORDS-1)) begin
                        entry_valid[fill_index]<=1;
                        if(fill_index==INDEX_BITS'(ENTRIES-1)) replacement_index<='0;
                        else replacement_index<=fill_index+1'b1;
                        state<=RESPONSE;
                    end else word_index<=word_index+1'b1;
                end
                RESPONSE: if (rsp_ready) state <= IDLE;
                default: begin
                    // Unreachable state recovery does not populate the cache.
                    rsp_fault <= 4'd1; response_metadata <= '0; state <= RESPONSE;
                end
            endcase
        end
    end
endmodule

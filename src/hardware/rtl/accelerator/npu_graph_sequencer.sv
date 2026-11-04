`timescale 1ns/1ps
// Profile-2 instruction scheduler. The checked package is immutable while this
// job owns it. Tensor records/TLV semantics and actual execution belong to the
// downstream backend; a supported-op mask is an executor capability contract.
module npu_graph_sequencer #(parameter bit PS_PREDECODED=1'b0) (
    input  logic clk,
    input  logic rst_n,

    input  logic cmd_valid,
    output logic cmd_ready,
    input  logic [31:0] cmd_task_id, cmd_frame_id, cmd_model_generation,
    input  logic [31:0] cmd_model_base, cmd_workspace_base,
    input  logic [31:0] cmd_model_id, cmd_profile,
    input  logic [31:0] cmd_image_bytes, cmd_workspace_bytes,
    input  logic [31:0] cmd_input_id, cmd_output_id, cmd_input_lut_id,
    // Slots: META, TENSORS, INSTRUCTIONS, ATTRIBUTES, CONSTANTS.
    input  logic [159:0] cmd_section_addr, cmd_section_bytes,
    input  logic [31:0] capability_op_mask,

    output logic mem_req_valid,
    input  logic mem_req_ready,
    output logic mem_req_write,
    output logic [31:0] mem_req_addr,
    output logic [1:0] mem_req_size,
    output logic [63:0] mem_req_wdata,
    input  logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input  logic signed [63:0] mem_rsp_rdata,
    input  logic [3:0] mem_rsp_fault,

    output logic op_cmd_valid,
    input  logic op_cmd_ready,
    output logic [1023:0] op_record,
    output logic [31:0] op_index,
    output logic [31:0] op_task_id, op_frame_id, op_model_generation,
    output logic [31:0] op_model_base, op_workspace_base,
    output logic [31:0] op_model_id, op_profile,
    output logic [31:0] op_image_bytes, op_workspace_bytes,
    output logic [31:0] op_input_id, op_output_id, op_input_lut_id,
    output logic [159:0] op_section_addr, op_section_bytes,

    input  logic op_rsp_valid,
    output logic op_rsp_ready,
    input  logic [31:0] op_rsp_task_id, op_rsp_frame_id,
    input  logic [31:0] op_rsp_model_generation, op_rsp_index,
    input  logic [7:0] op_rsp_fault,

    input  logic cancel_valid,
    output logic cancel_ready,
    input  logic [31:0] cancel_task_id, cancel_frame_id,
    input  logic [31:0] cancel_model_generation,
    // Cancellation payload is the held op_* task identity and op_index.
    output logic op_cancel_valid,
    input  logic op_cancel_ready,

    output logic rsp_valid,
    input  logic rsp_ready,
    output logic [31:0] rsp_task_id, rsp_frame_id, rsp_model_generation,
    output logic [31:0] rsp_model_id, rsp_profile, rsp_op_index,
    output logic [7:0] rsp_fault,
    output logic [7:0] rsp_backend_fault,
    output logic [3:0] rsp_memory_fault,
    output logic busy,
    output logic stale_event
);
    localparam logic [7:0] FAULT_NONE=0, FAULT_BAD_COMMAND=1,
        FAULT_MEMORY=2, FAULT_BAD_INSTRUCTION=3, FAULT_UNSUPPORTED=4,
        FAULT_CANCELLED=5, FAULT_BACKEND=6;
    typedef enum logic [2:0] {IDLE, CHECK_JOB, FETCH_REQUEST, FETCH_RESPONSE,
        CHECK_INSTRUCTION, OP_COMMAND, OP_EXECUTE, RESPONSE} state_t;
    state_t state;
    logic [31:0] op_mask, tensor_count, instruction_count;
    logic [4:0] word_index;
    logic job_bad, cancelled, cancel_sent;
    logic command_bad, instruction_bad, opcode_bad, opcode_supported;
    logic cancel_matches, cancel_now, stop_now;
    logic backend_matches, selected_response;
    logic [32:0] model_end_check, workspace_end_check, section_end_check;
    logic [32:0] attribute_end_check, fetch_address;

    function automatic logic [31:0] instruction_word(input integer index);
        instruction_word=op_record[index*32+:32];
    endfunction

    // Constant word enables avoid a runtime write selector across 1024 bits.
    // These are the same clear/admission/response conditions as the main FSM.
    generate for(genvar n=0;n<32;n=n+1) begin:g_instruction_word
      if(PS_PREDECODED && n!=0)begin:g_ps_unused
        // The compiled plan is authoritative for operands/attributes. The PS
        // checks the original tensor/TLV graph before publishing residency.
        // Preserve original op_index/opcode for backend ownership checks.
        assign op_record[n*32+:32]=32'd0;
      end else begin:g_checked_word
        always_ff @(posedge clk) begin
            if(!rst_n) op_record[n*32+:32]<=0;
            else if((state==IDLE && cmd_valid && cmd_ready) ||
                (selected_response && op_rsp_fault==0 && !stop_now &&
                 op_index+32'd1!=instruction_count)) op_record[n*32+:32]<=0;
            else if(state==FETCH_RESPONSE && mem_rsp_valid && mem_rsp_fault==0 &&
                !stop_now && word_index==5'(n)) op_record[n*32+:32]<=mem_rsp_rdata[31:0];
        end
      end
    end endgenerate

    // Recheck addressing at admission even though the package frontend normally
    // supplies this payload. End addresses are exclusive and may equal 2^32.
    always_comb begin
        model_end_check={1'b0,cmd_model_base}+{1'b0,cmd_image_bytes};
        workspace_end_check={1'b0,cmd_workspace_base}+{1'b0,cmd_workspace_bytes};
        command_bad=cmd_profile!=2 || (cmd_model_id<1 || cmd_model_id>3) ||
            cmd_model_base[11:0]!=0 || cmd_workspace_base[11:0]!=0 ||
            cmd_image_bytes==0 || cmd_image_bytes[11:0]!=0 ||
            cmd_workspace_bytes==0 || cmd_workspace_bytes[11:0]!=0 ||
            model_end_check>33'h100000000 || workspace_end_check>33'h100000000 ||
            ({1'b0,cmd_model_base}<workspace_end_check &&
             {1'b0,cmd_workspace_base}<model_end_check) ||
            cmd_section_bytes[32+:32]==0 || cmd_section_bytes[38:32]!=0 ||
            cmd_section_bytes[64+:32]==0 || cmd_section_bytes[70:64]!=0 ||
            cmd_input_id>=(cmd_section_bytes[32+:32]>>7) ||
            cmd_output_id>=(cmd_section_bytes[32+:32]>>7) ||
            (cmd_input_lut_id!=32'hffffffff &&
             cmd_input_lut_id>=(cmd_section_bytes[32+:32]>>7));
        section_end_check=0;
        for(integer s=0;s<5;s=s+1) begin
            section_end_check={1'b0,cmd_section_addr[s*32+:32]}+
                              {1'b0,cmd_section_bytes[s*32+:32]};
            if(cmd_section_addr[s*32+:12]!=0 ||
               {1'b0,cmd_section_addr[s*32+:32]}<{1'b0,cmd_model_base} ||
               section_end_check>model_end_check ||
               section_end_check>33'h100000000)
                command_bad=1'b1;
        end
    end

    always_comb begin
        opcode_bad=instruction_word(0)<1 || instruction_word(0)>20;
        opcode_supported=1'b0;
        if(!opcode_bad) opcode_supported=op_mask[op_record[4:0]];
        attribute_end_check=0;instruction_bad=0;
        if(!PS_PREDECODED)begin
         attribute_end_check={1'b0,instruction_word(12)}+
                             {1'b0,instruction_word(13)};
         instruction_bad=instruction_word(1)!=0 ||
            instruction_word(2)<1 || instruction_word(2)>4 ||
            instruction_word(3)<1 || instruction_word(3)>4 ||
            attribute_end_check>{1'b0,op_section_bytes[96+:32]};
        for(integer n=0;n<4;n=n+1) begin
            if(n<instruction_word(2)) begin
                if(instruction_word(4+n)>=tensor_count) instruction_bad=1'b1;
            end else if(instruction_word(4+n)!=32'hffffffff) instruction_bad=1'b1;
            if(n<instruction_word(3)) begin
                if(instruction_word(8+n)>=tensor_count) instruction_bad=1'b1;
            end else if(instruction_word(8+n)!=32'hffffffff) instruction_bad=1'b1;
        end
         for(integer n=15;n<32;n=n+1)
             if(instruction_word(n)!=0) instruction_bad=1'b1;
        end
    end

    always_comb begin
        cmd_ready=rst_n && state==IDLE;
        busy=state!=IDLE;
        rsp_valid=rst_n && state==RESPONSE;
        rsp_task_id=op_task_id;
        rsp_frame_id=op_frame_id;
        rsp_model_generation=op_model_generation;
        rsp_model_id=op_model_id;
        rsp_profile=op_profile;
        rsp_op_index=op_index;
        mem_req_valid=rst_n && state==FETCH_REQUEST;
        mem_req_write=1'b0;
        // All offsets are widened before the additions. Admission checks and
        // instruction_count bound ensure the selected word fits its section.
        fetch_address={1'b0,op_section_addr[64+:32]}+
                      ({1'b0,op_index}<<7)+
                      (PS_PREDECODED ? 33'd0 : {26'd0,word_index,2'b0});
        mem_req_addr=fetch_address[31:0];
        mem_req_size=2'd2;
        mem_req_wdata=64'd0;
        mem_rsp_ready=rst_n && state==FETCH_RESPONSE;
        op_cmd_valid=rst_n && state==OP_COMMAND;
        op_rsp_ready=rst_n;
        backend_matches=op_rsp_task_id==op_task_id &&
            op_rsp_frame_id==op_frame_id &&
            op_rsp_model_generation==op_model_generation && op_rsp_index==op_index;
        selected_response=op_rsp_valid && backend_matches &&
            (state==OP_EXECUTE || (state==OP_COMMAND && op_cmd_ready));
        cancel_ready=rst_n;
        cancel_matches=cancel_task_id==op_task_id && cancel_frame_id==op_frame_id &&
            cancel_model_generation==op_model_generation;
        cancel_now=cancel_valid && cancel_matches && state!=IDLE && state!=RESPONSE;
        stop_now=cancelled || cancel_now;
        // Record matching cancellation and completion on their original edge,
        // but forward only the sticky stop to an accepted backend operation.
        // This isolates its FSM from the 96-bit task-identity comparison.
        // Held commands and terminal-response/fault priority are unchanged.
        op_cancel_valid=rst_n && state==OP_EXECUTE && cancelled && !cancel_sent;
    end

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;
            op_index<=0;
            op_task_id<=0; op_frame_id<=0; op_model_generation<=0;
            op_model_base<=0; op_workspace_base<=0; op_model_id<=0; op_profile<=0;
            op_image_bytes<=0; op_workspace_bytes<=0;
            op_input_id<=0; op_output_id<=0; op_input_lut_id<=0;
            op_section_addr<=0; op_section_bytes<=0;
            op_mask<=0; tensor_count<=0; instruction_count<=0; word_index<=0;
            job_bad<=0; cancelled<=0; cancel_sent<=0;
            rsp_fault<=FAULT_NONE; rsp_backend_fault<=0; rsp_memory_fault<=0;
            stale_event<=0;
        end else begin
            stale_event<=0;
            if(cancel_valid && cancel_ready) begin
                if(cancel_now) cancelled<=1'b1;
                else stale_event<=1'b1;
            end
            // A response may retire only an accepted current operation. Other
            // identities are consumed so a stale producer cannot block fabric.
            if(op_rsp_valid && op_rsp_ready && !selected_response) stale_event<=1'b1;
            case(state)
                IDLE: if(cmd_valid && cmd_ready) begin
                    op_task_id<=cmd_task_id; op_frame_id<=cmd_frame_id;
                    op_model_generation<=cmd_model_generation;
                    op_model_base<=cmd_model_base; op_workspace_base<=cmd_workspace_base;
                    op_model_id<=cmd_model_id; op_profile<=cmd_profile;
                    op_image_bytes<=cmd_image_bytes; op_workspace_bytes<=cmd_workspace_bytes;
                    op_input_id<=cmd_input_id; op_output_id<=cmd_output_id;
                    op_input_lut_id<=cmd_input_lut_id;
                    op_section_addr<=cmd_section_addr; op_section_bytes<=cmd_section_bytes;
                    op_mask<=capability_op_mask;
                    tensor_count<=cmd_section_bytes[32+:32]>>7;
                    instruction_count<=cmd_section_bytes[64+:32]>>7;
                    job_bad<=command_bad; cancelled<=0; cancel_sent<=0;
                    word_index<=0; op_index<=0;
                    rsp_fault<=FAULT_NONE; rsp_backend_fault<=0; rsp_memory_fault<=0;
                    state<=CHECK_JOB;
                end
                CHECK_JOB: begin
                    if(job_bad) begin rsp_fault<=FAULT_BAD_COMMAND; state<=RESPONSE; end
                    else if(stop_now) begin rsp_fault<=FAULT_CANCELLED; state<=RESPONSE; end
                    else state<=FETCH_REQUEST;
                end
                // Once this state exposes VALID, cancellation cannot revoke the
                // command, even if READY has not yet arrived.
                FETCH_REQUEST: if(mem_req_ready) state<=FETCH_RESPONSE;
                FETCH_RESPONSE: if(mem_rsp_valid) begin
                    if(mem_rsp_fault!=0) begin
                        rsp_fault<=FAULT_MEMORY; rsp_memory_fault<=mem_rsp_fault;
                        state<=RESPONSE;
                    end else if(stop_now) begin
                        rsp_fault<=FAULT_CANCELLED; state<=RESPONSE;
                    end else begin
                        if(PS_PREDECODED || word_index==31) state<=CHECK_INSTRUCTION;
                        else begin word_index<=word_index+1'b1; state<=FETCH_REQUEST; end
                    end
                end
                CHECK_INSTRUCTION: begin
                    if(opcode_bad || instruction_bad) begin
                        rsp_fault<=FAULT_BAD_INSTRUCTION; state<=RESPONSE;
                    end else if(!opcode_supported) begin
                        rsp_fault<=FAULT_UNSUPPORTED; state<=RESPONSE;
                    end else if(stop_now) begin
                        rsp_fault<=FAULT_CANCELLED; state<=RESPONSE;
                    end else state<=OP_COMMAND;
                end
                OP_COMMAND: if(op_cmd_ready) state<=OP_EXECUTE;
                OP_EXECUTE: if(op_cancel_valid && op_cancel_ready) cancel_sent<=1'b1;
                RESPONSE: if(rsp_ready) state<=IDLE;
                default: begin rsp_fault<=FAULT_BAD_COMMAND; state<=RESPONSE; end
            endcase
            // Also handles a terminal response in the command acceptance cycle.
            // Backend failure wins over a simultaneous matching cancellation.
            if(selected_response) begin
                cancel_sent<=0;
                if(op_rsp_fault!=0) begin
                    rsp_fault<=FAULT_BACKEND; rsp_backend_fault<=op_rsp_fault;
                    state<=RESPONSE;
                end else if(stop_now) begin
                    rsp_fault<=FAULT_CANCELLED; state<=RESPONSE;
                end else if(op_index+32'd1==instruction_count) begin
                    rsp_fault<=FAULT_NONE; state<=RESPONSE;
                end else begin
                    op_index<=op_index+1'b1; word_index<=0;
                    state<=FETCH_REQUEST;
                end
            end
        end
    end
endmodule

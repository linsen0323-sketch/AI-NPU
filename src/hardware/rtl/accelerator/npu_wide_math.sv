`timescale 1ns/1ps
// Shared, exact ADD/MUL/RSHIFT arithmetic for ResNet18 and YOLOX.
// Pipelined DSP partial products and staged shifts retain the integer ABI.
// One outstanding request; the response remains stable until accepted.
// op 0 ADD: signed a+b, shift ignored.
// op 1 MUL_RSHIFT: RNE(signed(a)*signed(b)/2^shift), 0 <= shift <= 127.
// op 2 RSHIFT: RNE(signed(a)/2^shift), 0 <= shift <= 64.
// A fault response has result=0: 1 invalid op/domain, 2 result overflow.
module npu_wide_math (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               req_valid,
    output logic               req_ready,
    input  logic [2:0]         req_op,
    input  logic signed [63:0] req_a,
    input  logic signed [63:0] req_b,
    input  logic [6:0]         req_shift,
    output logic               rsp_valid,
    input  logic               rsp_ready,
    output logic signed [63:0] rsp_result,
    output logic [1:0]         rsp_fault
);
 npu_wide_math_fast u_core(.*);
endmodule


// Engines keep a standalone implementation unless the integrated dispatcher
// supplies the shared arithmetic service. No arithmetic is duplicated in the
// external branch.
module npu_math_port #(
    parameter bit EXTERNAL_MATH = 1'b0
) (
    input logic clk,rst_n,
    input logic req_valid,output logic req_ready,
    input logic [2:0] req_op,
    input logic signed [63:0] req_a,req_b,
    input logic [6:0] req_shift,
    output logic rsp_valid,input logic rsp_ready,
    output logic signed [63:0] rsp_result,output logic [1:0] rsp_fault,
    output logic math_req_valid,input logic math_req_ready,
    output logic [2:0] math_req_op,
    output logic signed [63:0] math_req_a,math_req_b,
    output logic [6:0] math_req_shift,
    input logic math_rsp_valid,output logic math_rsp_ready,
    input logic signed [63:0] math_rsp_result,input logic [1:0] math_rsp_fault
);
    generate
        if (EXTERNAL_MATH) begin : g_external
            assign math_req_valid = req_valid;
            assign req_ready = math_req_ready;
            assign math_req_op = req_op;
            assign math_req_a = req_a;
            assign math_req_b = req_b;
            assign math_req_shift = req_shift;
            assign rsp_valid = math_rsp_valid;
            assign math_rsp_ready = rsp_ready;
            assign rsp_result = math_rsp_result;
            assign rsp_fault = math_rsp_fault;
        end else begin : g_local
            assign math_req_valid = 1'b0;
            assign math_req_op = '0;
            assign math_req_a = '0;
            assign math_req_b = '0;
            assign math_req_shift = '0;
            assign math_rsp_ready = 1'b0;
            npu_wide_math u_math (
                .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),
                .req_op(req_op),.req_a(req_a),.req_b(req_b),.req_shift(req_shift),
                .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
                .rsp_result(rsp_result),.rsp_fault(rsp_fault)
            );
        end
    endgenerate
endmodule

// One buffered request and one owner retained through the terminal response.
// Result data is broadcast; only VALID is decoded per client, avoiding a wide
// variable-position response demultiplexer.
module npu_math_fabric #(
    parameter integer CLIENTS = 2,
    parameter integer OWNER_BITS = (CLIENTS<=1) ? 1 : $clog2(CLIENTS)
) (
    input logic clk,rst_n,
    input logic [CLIENTS-1:0] c_req_valid,output logic [CLIENTS-1:0] c_req_ready,
    input logic [CLIENTS*3-1:0] c_req_op,
    input logic [CLIENTS*64-1:0] c_req_a,c_req_b,
    input logic [CLIENTS*7-1:0] c_req_shift,
    output logic [CLIENTS-1:0] c_rsp_valid,input logic [CLIENTS-1:0] c_rsp_ready,
    output logic signed [63:0] c_rsp_result,output logic [1:0] c_rsp_fault,
    output logic req_valid,input logic req_ready,output logic [2:0] req_op,
    output logic signed [63:0] req_a,req_b,output logic [6:0] req_shift,
    input logic rsp_valid,output logic rsp_ready,
    input logic signed [63:0] rsp_result,input logic [1:0] rsp_fault,
    output logic idle
);
    typedef enum logic [1:0] {SELECT,SEND,RESPONSE} state_t;
    state_t state;
    logic [OWNER_BITS-1:0] owner;
    logic found;
    integer chosen;
    always_comb begin
        chosen=0;found=0;c_req_ready='0;c_rsp_valid='0;rsp_ready=0;
        for(integer n=0;n<CLIENTS;n=n+1) begin
            if(!found && c_req_valid[n]) begin chosen=n;found=1;end
        end
        if(rst_n && state==SELECT && found) c_req_ready[chosen]=1;
        for(integer n=0;n<CLIENTS;n=n+1) begin
            if(rst_n && state==RESPONSE && owner==OWNER_BITS'(n)) begin
                c_rsp_valid[n]=rsp_valid;rsp_ready=c_rsp_ready[n];
            end
        end
        req_valid=rst_n && state==SEND;
        c_rsp_result=rsp_result;c_rsp_fault=rsp_fault;
        idle=rst_n && state==SELECT && !found;
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=SELECT;owner<='0;req_op<='0;req_a<='0;req_b<='0;req_shift<='0;
        end else case(state)
            SELECT: if(found) begin
                owner<=OWNER_BITS'(chosen);
                req_op<=c_req_op[chosen*3+:3];
                req_a<=c_req_a[chosen*64+:64];req_b<=c_req_b[chosen*64+:64];
                req_shift<=c_req_shift[chosen*7+:7];state<=SEND;
            end
            SEND: if(req_ready) state<=RESPONSE;
            RESPONSE: if(rsp_valid && rsp_ready) state<=SELECT;
            default: state<=SELECT;
        endcase
    end
endmodule

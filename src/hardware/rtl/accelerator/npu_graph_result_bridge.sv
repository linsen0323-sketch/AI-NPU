`timescale 1ns/1ps
// Completion-side descriptor bridge for profile-2 graph tasks.
//
// The graph executor writes its final tensor into the leased workspace.  The
// descriptor is supplied by the host together with START and is held across
// the complete task.  A result is published only by the executor's terminal
// completion event, after the model-control drain condition has been met.
// The published descriptor is sticky until the host clears it through the
// graph register window, so a slow PS reader cannot lose a completion.
module npu_graph_result_bridge (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start_fire,
    input  logic [31:0] start_output_addr,
    input  logic [31:0] start_output_bytes,
    input  logic [7:0]  start_output_dtype,
    input  logic        done_valid,
    output logic        done_ready,
    input  logic [31:0] done_task_id,
    input  logic [31:0] done_frame_id,
    input  logic [31:0] done_generation,
    input  logic [31:0] done_model_id,
    input  logic [15:0] done_fault,
    input  logic        clear_valid,
    output logic        result_valid,
    output logic [31:0] result_output_addr,
    output logic [31:0] result_output_bytes,
    output logic [7:0]  result_output_dtype,
    output logic [31:0] result_task_id,
    output logic [31:0] result_frame_id,
    output logic [31:0] result_generation,
    output logic [31:0] result_model_id,
    output logic [15:0] result_fault
);
    logic [31:0] active_output_addr;
    logic [31:0] active_output_bytes;
    logic [7:0]  active_output_dtype;

    assign done_ready = 1'b1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_output_addr  <= 32'd0;
            active_output_bytes <= 32'd0;
            active_output_dtype <= 8'd0;
            result_valid        <= 1'b0;
            result_output_addr  <= 32'd0;
            result_output_bytes <= 32'd0;
            result_output_dtype <= 8'd0;
            result_task_id      <= 32'd0;
            result_frame_id     <= 32'd0;
            result_generation   <= 32'd0;
            result_model_id     <= 32'd0;
            result_fault        <= 16'd0;
        end else begin
            if (clear_valid && !done_valid)
                result_valid <= 1'b0;

            if (start_fire) begin
                active_output_addr  <= start_output_addr;
                active_output_bytes <= start_output_bytes;
                active_output_dtype <= start_output_dtype;
            end

            if (done_valid && done_ready) begin
                result_valid        <= 1'b1;
                result_output_addr  <= active_output_addr;
                result_output_bytes <= active_output_bytes;
                result_output_dtype <= active_output_dtype;
                result_task_id      <= done_task_id;
                result_frame_id     <= done_frame_id;
                result_generation   <= done_generation;
                result_model_id     <= done_model_id;
                result_fault        <= done_fault;
            end
        end
    end
endmodule

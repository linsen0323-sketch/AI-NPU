`timescale 1ns/1ps
// Serial task owner for the checked AIPKG3 frontend and two profile executors.
// A checked package is not an executor capability. Both capabilities default to
// external inputs and are sampled when a task is admitted. No memory operation
// is abandoned on cancellation: accepted frontend/executor work must respond,
// and every read/write/FIFO/compute path must drain before workspace_release.
module npu_task_controller (
 input logic clk, rst_n,
 input logic start_valid, output logic start_ready,
 input logic [31:0] start_model_base, start_model_capacity,
 input logic [31:0] start_workspace_base, start_workspace_capacity,
 input logic [31:0] start_frame_id, start_model_generation,
 input logic capability_legacy, capability_graph,
 output logic busy, workspace_owned,
 output logic [31:0] active_task_id, active_frame_id, active_model_generation,
 output logic workspace_release,

 output logic fe_cmd_valid, input logic fe_cmd_ready,
 output logic [31:0] fe_model_base, fe_model_capacity,
 output logic [31:0] fe_workspace_base, fe_workspace_capacity,
 input logic fe_rsp_valid, output logic fe_rsp_ready,
 input logic [3:0] fe_rsp_fault,
 input logic [31:0] fe_rsp_model_id, fe_rsp_profile,
 input logic [31:0] fe_rsp_image_bytes, fe_rsp_workspace_bytes,
 input logic [31:0] fe_rsp_input_id, fe_rsp_output_id, fe_rsp_input_lut_id,
 input logic [159:0] fe_rsp_section_addr, fe_rsp_section_bytes,

 output logic legacy_cmd_valid, input logic legacy_cmd_ready,
 output logic graph_cmd_valid, input logic graph_cmd_ready,
 // Payload shared between the two exclusive command-valid interfaces.
 output logic [31:0] exec_task_id, exec_frame_id, exec_model_generation,
 output logic [31:0] exec_model_base, exec_workspace_base,
 output logic [31:0] exec_model_id, exec_profile,
 output logic [31:0] exec_image_bytes, exec_workspace_bytes,
 output logic [31:0] exec_input_id, exec_output_id, exec_input_lut_id,
 output logic [159:0] exec_section_addr, exec_section_bytes,

 input logic legacy_rsp_valid, output logic legacy_rsp_ready,
 input logic [31:0] legacy_rsp_task_id, legacy_rsp_frame_id, legacy_rsp_model_generation,
 input logic [7:0] legacy_rsp_fault,
 input logic graph_rsp_valid, output logic graph_rsp_ready,
 input logic [31:0] graph_rsp_task_id, graph_rsp_frame_id, graph_rsp_model_generation,
 input logic [7:0] graph_rsp_fault,

 input logic cancel_valid, output logic cancel_ready,
 input logic [31:0] cancel_task_id, cancel_frame_id, cancel_model_generation,
 output logic legacy_cancel_valid, input logic legacy_cancel_ready,
 output logic graph_cancel_valid, input logic graph_cancel_ready,
 // Cancel payload is exec_task_id/frame_id/model_generation above. Accepting
 // a cancel request does not retire work; the executor must still respond.
 input logic async_fault_valid, input logic [7:0] async_fault_code,
 input logic reads_idle, writes_idle, fifos_idle, compute_idle,

 output logic done_valid, input logic done_ready,
 output logic [31:0] done_task_id, done_frame_id, done_model_generation,
 output logic [31:0] done_model_id, done_profile,
 output logic [15:0] done_fault,
 output logic stale_event
);
 typedef enum logic [2:0] {IDLE, FE_COMMAND, FE_RESPONSE, DISPATCH, EXECUTE, DRAIN, COMPLETE} state_t;
 state_t state;
 logic [31:0] sequence_number;
 logic cap_legacy, cap_graph, cancelled, cancel_sent;
 logic [15:0] fault;
 logic cancel_matches, cancel_now, stop_now, executor_accepted;
 logic legacy_matches, graph_matches, selected_response;
 logic [7:0] selected_fault;
 logic all_drained;

 always_comb begin
  busy = state != IDLE;
  workspace_owned = state != IDLE && state != COMPLETE;
  start_ready = rst_n && state == IDLE;
  cancel_ready = rst_n;
  cancel_matches = cancel_task_id == active_task_id &&
    cancel_frame_id == active_frame_id && cancel_model_generation == active_model_generation;
  cancel_now = cancel_valid && cancel_matches && workspace_owned;
  stop_now = cancelled || cancel_now || async_fault_valid;
  fe_cmd_valid = rst_n && state == FE_COMMAND;
  fe_rsp_ready = rst_n && state == FE_RESPONSE;
  legacy_cmd_valid = rst_n && state == DISPATCH && exec_profile == 1;
  graph_cmd_valid = rst_n && state == DISPATCH && exec_profile == 2;
  executor_accepted = (legacy_cmd_valid && legacy_cmd_ready) || (graph_cmd_valid && graph_cmd_ready);
  // Stale responses are consumed and flagged, never allowed to retire a task.
  legacy_rsp_ready = rst_n;
  graph_rsp_ready = rst_n;
  legacy_matches = legacy_rsp_task_id == active_task_id &&
    legacy_rsp_frame_id == active_frame_id && legacy_rsp_model_generation == active_model_generation;
  graph_matches = graph_rsp_task_id == active_task_id &&
    graph_rsp_frame_id == active_frame_id && graph_rsp_model_generation == active_model_generation;
  selected_response = 0;
  selected_fault = 0;
  if(state == EXECUTE || (state == DISPATCH && executor_accepted)) begin
   if(exec_profile == 1 && legacy_rsp_valid && legacy_matches) begin
    selected_response = 1; selected_fault = legacy_rsp_fault;
   end
   if(exec_profile == 2 && graph_rsp_valid && graph_matches) begin
    selected_response = 1; selected_fault = graph_rsp_fault;
   end
  end
  // The parent still records stop_now on its original edge, including when
  // completion and cancellation coincide. Forward only the sticky registered
  // stop to children, cutting the 96-bit identity comparison out of their
  // FSM paths. One extra child-cancel cycle never releases an accepted lease:
  // terminal response and all four drain indications are still mandatory.
  legacy_cancel_valid = rst_n && state == EXECUTE && exec_profile == 1 && cancelled && !cancel_sent;
  graph_cancel_valid = rst_n && state == EXECUTE && exec_profile == 2 && cancelled && !cancel_sent;
  all_drained = reads_idle && writes_idle && fifos_idle && compute_idle;
  done_valid = rst_n && state == COMPLETE;
  done_task_id = active_task_id; done_frame_id = active_frame_id;
  done_model_generation = active_model_generation;
  done_model_id = exec_model_id; done_profile = exec_profile; done_fault = fault;
  exec_task_id = active_task_id; exec_frame_id = active_frame_id;
  exec_model_generation = active_model_generation;
  exec_model_base = fe_model_base; exec_workspace_base = fe_workspace_base;
 end

 always_ff @(posedge clk) begin
  if(!rst_n) begin
   state <= IDLE; sequence_number <= 0;
   active_task_id <= 0; active_frame_id <= 0; active_model_generation <= 0;
   cap_legacy <= 0; cap_graph <= 0; cancelled <= 0; cancel_sent <= 0; fault <= 0;
   fe_model_base <= 0; fe_model_capacity <= 0; fe_workspace_base <= 0; fe_workspace_capacity <= 0;
   exec_model_id <= 0; exec_profile <= 0; exec_image_bytes <= 0; exec_workspace_bytes <= 0;
   exec_input_id <= 0; exec_output_id <= 0; exec_input_lut_id <= 0;
   exec_section_addr <= 0; exec_section_bytes <= 0;
   workspace_release <= 0; stale_event <= 0;
  end else begin
   workspace_release <= 0; stale_event <= 0;
   if(cancel_valid) begin
    if(cancel_now) cancelled <= 1;
    else stale_event <= 1;
   end
   if(legacy_rsp_valid && !(selected_response && exec_profile == 1 && legacy_matches)) stale_event <= 1;
   if(graph_rsp_valid && !(selected_response && exec_profile == 2 && graph_matches)) stale_event <= 1;
   // First failure is retained. Frontend/executor faults below take precedence
   // over a simultaneous cancellation of otherwise successful work.
   if(workspace_owned && async_fault_valid && fault == 0) begin
    fault <= {8'h05,async_fault_code}; cancelled <= 1;
   end else if(cancel_now && fault == 0) fault <= 16'h0301;
   case(state)
    IDLE: if(start_valid) begin
     sequence_number <= sequence_number + 1'b1;
     active_task_id <= sequence_number + 1'b1;
     active_frame_id <= start_frame_id; active_model_generation <= start_model_generation;
     fe_model_base <= start_model_base; fe_model_capacity <= start_model_capacity;
     fe_workspace_base <= start_workspace_base; fe_workspace_capacity <= start_workspace_capacity;
     cap_legacy <= capability_legacy; cap_graph <= capability_graph;
     cancelled <= 0; cancel_sent <= 0; fault <= 0;
     // Execution payload is valid only after FE_RESPONSE captures every field.
     // Cancellation and faults also wait for that response before completion.
     state <= FE_COMMAND;
    end
    FE_COMMAND: if(fe_cmd_ready) state <= FE_RESPONSE;
    FE_RESPONSE: if(fe_rsp_valid) begin
     exec_model_id <= fe_rsp_model_id; exec_profile <= fe_rsp_profile;
     exec_image_bytes <= fe_rsp_image_bytes; exec_workspace_bytes <= fe_rsp_workspace_bytes;
     exec_input_id <= fe_rsp_input_id; exec_output_id <= fe_rsp_output_id;
     exec_input_lut_id <= fe_rsp_input_lut_id;
     exec_section_addr <= fe_rsp_section_addr; exec_section_bytes <= fe_rsp_section_bytes;
     if(fe_rsp_fault != 0) begin
      if(fault == 0 || fault == 16'h0301) fault <= {8'h01,4'd0,fe_rsp_fault};
      state <= DRAIN;
     end else if(stop_now) state <= DRAIN;
     else if((fe_rsp_profile == 1 && !cap_legacy) || (fe_rsp_profile == 2 && !cap_graph)) begin
      fault <= 16'h0201; state <= DRAIN;
     end else if(fe_rsp_profile != 1 && fe_rsp_profile != 2) begin
      fault <= 16'h0202; state <= DRAIN;
     end else state <= DISPATCH;
    end
    // Once valid has been presented, cancellation cannot revoke the command.
    // Accept it, request cancellation, and wait for its terminal response.
    DISPATCH: if(executor_accepted) begin
     if(selected_response) begin
      if(selected_fault != 0 && (fault == 0 || fault == 16'h0301)) fault <= {8'h04,selected_fault};
      state <= DRAIN;
     end else state <= EXECUTE;
    end
    EXECUTE: begin
     if((legacy_cancel_valid && legacy_cancel_ready) || (graph_cancel_valid && graph_cancel_ready)) cancel_sent <= 1;
     if(selected_response) begin
      if(selected_fault != 0 && (fault == 0 || fault == 16'h0301)) fault <= {8'h04,selected_fault};
      state <= DRAIN;
     end
    end
    DRAIN: if(all_drained) begin workspace_release <= 1; state <= COMPLETE; end
    COMPLETE: if(done_ready) state <= IDLE;
    default: state <= IDLE;
   endcase
  end
 end
endmodule

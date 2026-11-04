`timescale 1ns/1ps
// Graph control window at camera S_AXI + 0x8000. Linux/SD are not required.
// MODE=1 enables PS-managed graph jobs; MODE=0 disables admission.
// Former automatic-camera ARM at 0x84 is reserved: zero is accepted, one rejected.
module npu_graph_registers #(
 parameter integer CLOCK_HZ=150000000,
 parameter bit PS_PREDECODED=1'b1,
 parameter bit ENABLE_PROFILE_TRACE=1'b1,ENABLE_STALL_DIAG=1'b1,ENABLE_PERF_COUNTERS=1'b1
) (
 output logic stall_arm,stall_clear,output logic [31:0] stall_target,output logic [7:0] stall_select,
 input wire [31:0] stall_data,stall_status,stall_frame,stall_generation,stall_task,stall_model,stall_index,stall_fault,
 output logic profile_arm,output logic [11:0] profile_select,
 input wire [31:0] profile_data,profile_status,profile_frame,profile_generation,profile_task,
 input logic [63:0] perf_read_bytes,perf_write_bytes,perf_read_wait,perf_write_wait,perf_pe_vectors,perf_pe_wait,
 input logic [31:0] perf_read_bursts,perf_write_bursts,
 input logic [2:0] perf_max_reads,input logic [1:0] perf_max_writes,
 input logic clk,rst_n,
 output logic start_valid,input logic start_ready,
 output logic [31:0] model_base,model_capacity,workspace_base,workspace_capacity,plan_base,plan_capacity,frame_id,generation,
 output logic [31:0] output_addr,output_bytes,
 output logic [31:0] input_addr,input_bytes,
 output logic [7:0] output_dtype,
 output logic cancel_valid,input logic cancel_ready,output logic invalidate_valid,input logic invalidate_ready,
 output logic result_clear,input logic result_blocked,input logic result_valid,
 input logic [31:0] result_output_addr,result_output_bytes,
 input logic [7:0] result_output_dtype,
 input logic graph_busy,input logic [31:0] active_task_id,active_frame_id,active_generation,current_op_index,
 input logic done_valid,output logic done_ready,input logic [31:0] done_task_id,done_frame_id,done_generation,done_model_id,
 input logic [15:0] done_fault,
 input logic [15:0] s_axi_awaddr,input logic s_axi_awvalid,output logic s_axi_awready,
 input logic [31:0] s_axi_wdata,input logic [3:0] s_axi_wstrb,input logic s_axi_wvalid,output logic s_axi_wready,
 output logic [1:0] s_axi_bresp,output logic s_axi_bvalid,input logic s_axi_bready,
 input logic [15:0] s_axi_araddr,input logic s_axi_arvalid,output logic s_axi_arready,
 output logic [31:0] s_axi_rdata,output logic [1:0] s_axi_rresp,output logic s_axi_rvalid,input logic s_axi_rready
);
 logic aw_hold,w_hold;logic [15:0] aw;logic [31:0] wd;logic [3:0] strobe;
 logic pending,cancel_pending,invalidate_pending,done_sticky;
 logic [15:0] last_fault;logic [31:0] last_task,last_frame,last_generation,last_model;
 logic [63:0] cycles,last_cycles;
 logic configurable,output_config_bad;
 logic mode_requested,mode_owned;
 logic [32:0] output_end,workspace_end;
 function automatic logic [31:0] merge(input logic [31:0] old_value,new_value,input logic [3:0] mask);
  logic [31:0] value;begin value=old_value;for(integer b=0;b<4;b=b+1) if(mask[b]) value[b*8+:8]=new_value[b*8+:8];merge=value;end
 endfunction
 assign workspace_end={1'b0,workspace_base}+{1'b0,workspace_capacity};
 assign output_end={1'b0,output_addr}+{1'b0,output_bytes};
 assign output_config_bad=output_bytes==0 || output_addr==0 ||
  (output_dtype<1 || output_dtype>4) ||
  ((output_dtype==4) ? (output_addr[2:0]!=0) :
   ((output_dtype==3) ? (output_addr[1:0]!=0) :
    ((output_dtype==2) ? output_addr[0] : 1'b0))) ||
  ((output_dtype==2) ? output_bytes[0] :
   ((output_dtype==3) ? (|output_bytes[1:0]) :
    ((output_dtype==4) ? (|output_bytes[2:0]) : 1'b0))) ||
  ({1'b0,output_addr}<{1'b0,workspace_base}) || output_end>workspace_end ||
  output_end>33'h100000000;
 assign configurable=!graph_busy && !pending && !invalidate_pending && !result_blocked;
 assign s_axi_awready=rst_n && !aw_hold && !s_axi_bvalid;
 assign s_axi_wready=rst_n && !w_hold && !s_axi_bvalid;
 assign s_axi_arready=rst_n && !s_axi_rvalid;
 assign start_valid=rst_n && pending && mode_owned && !result_blocked;
 assign cancel_valid=rst_n && cancel_pending && graph_busy;
 assign invalidate_valid=rst_n && invalidate_pending;
 assign done_ready=1'b1;
 // Feature word at 0xFC: ASCII DIA in bits31:8; bits2:0 are
 // PERF_COUNTERS, STALL_DIAG, PROFILE_TRACE. All-enabled defaults preserve
 // existing IDs/capabilities. Disabled known read addresses return 0/OKAY;
 // disabled diagnostic writes return SLVERR without side effects.
 localparam [31:0] DIAGNOSTIC_FEATURES=32'h44494100 |
    (ENABLE_PROFILE_TRACE ? 32'd1:32'd0) |
    (ENABLE_STALL_DIAG ? 32'd2:32'd0) |
    (ENABLE_PERF_COUNTERS ? 32'd4:32'd0);
 wire write_commit=aw_hold&&w_hold&&!s_axi_bvalid;
 generate
  if(ENABLE_PROFILE_TRACE)begin:g_profile_csrs
   always_ff @(posedge clk)begin
    if(!rst_n)begin profile_arm<=0;profile_select<=0;end
    else begin
     profile_arm<=0;
     if(write_commit&&aw[14:8]==0&&aw[1:0]==0)case(aw[7:0])
      8'he0:if(strobe[0]&&wd[0]&&!profile_status[17])profile_arm<=1;
      8'he4:profile_select<=12'(merge({20'd0,profile_select},wd,strobe));
      default:;
     endcase
    end
   end
  end else begin:g_no_profile_csrs
   assign profile_arm=0;assign profile_select=0;
  end
  if(ENABLE_STALL_DIAG)begin:g_stall_csrs
   always_ff @(posedge clk)begin
    if(!rst_n)begin stall_arm<=0;stall_clear<=0;stall_target<=16;stall_select<=0;end
    else begin
     stall_arm<=0;stall_clear<=0;
     if(write_commit&&aw[14:8]==1&&aw[1:0]==0)case(aw[7:0])
      8'h04:if(!stall_status[1]&&!stall_status[7])stall_target<=merge(stall_target,wd,strobe);
      8'h08:if(strobe[0])begin
       if(wd[1])stall_clear<=1;
       else if(wd[0]&&!graph_busy&&!pending&&!stall_status[1]&&!stall_status[7])stall_arm<=1;
      end
      8'h0c:stall_select<=8'(merge({24'd0,stall_select},wd,strobe));
      default:;
     endcase
    end
   end
  end else begin:g_no_stall_csrs
   assign stall_arm=0;assign stall_clear=0;assign stall_target=0;assign stall_select=0;
  end
  // Task-cycle statistics are passive. Watchdog/timeout lives in execution
  // control and is deliberately unaffected by this parameter.
  if(ENABLE_PERF_COUNTERS)begin:g_cycle_counters
   always_ff @(posedge clk)begin
    if(!rst_n)begin cycles<=0;last_cycles<=0;end
    else begin
     if(start_valid&&start_ready)cycles<=0;
     else if(graph_busy)cycles<=cycles+1'b1;
     if(done_valid)last_cycles<=cycles;
    end
   end
  end else begin:g_no_cycle_counters
   assign cycles=0;assign last_cycles=0;
  end
 endgenerate
 always_ff @(posedge clk) begin
  if(!rst_n) begin
   aw_hold<=0;w_hold<=0;aw<=0;wd<=0;strobe<=0;s_axi_bvalid<=0;s_axi_bresp<=0;s_axi_rvalid<=0;s_axi_rresp<=0;s_axi_rdata<=0;
   result_clear<=0;
   mode_requested<=0;mode_owned<=0;pending<=0;cancel_pending<=0;invalidate_pending<=0;done_sticky<=0;
   model_base<=0;model_capacity<=0;workspace_base<=0;workspace_capacity<=0;plan_base<=0;plan_capacity<=0;frame_id<=0;generation<=0;
   output_addr<=0;output_bytes<=0;output_dtype<=0;
   input_addr<=0;input_bytes<=0;
   last_fault<=0;last_task<=0;last_frame<=0;last_generation<=0;last_model<=0;
  end else begin
   if(!graph_busy && !pending && !invalidate_pending) mode_owned<=mode_requested;
   result_clear<=0;
   if(start_valid && start_ready) begin pending<=0;done_sticky<=0;last_fault<=0;end
   if(cancel_valid && cancel_ready) cancel_pending<=0;
   if(invalidate_valid && invalidate_ready) invalidate_pending<=0;
   if(done_valid) begin
    done_sticky<=1;last_fault<=done_fault;last_task<=done_task_id;last_frame<=done_frame_id;
    last_generation<=done_generation;last_model<=done_model_id;cancel_pending<=0;
   end
   if(s_axi_awvalid && s_axi_awready) begin aw<=s_axi_awaddr;aw_hold<=1;end
   if(s_axi_wvalid && s_axi_wready) begin wd<=s_axi_wdata;strobe<=s_axi_wstrb;w_hold<=1;end
   if(s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
   if(aw_hold && w_hold && !s_axi_bvalid) begin
    aw_hold<=0;w_hold<=0;s_axi_bvalid<=1;s_axi_bresp<=0;
    if(aw[14:8]==7'd1 && aw[1:0]==0)begin
     if(!ENABLE_STALL_DIAG)s_axi_bresp<=2'b10;
     else case(aw[7:0])
      8'h04:if(stall_status[1]||stall_status[7])s_axi_bresp<=2'b10;
      8'h08:if(strobe[0]&&!wd[1]&&wd[0] &&
         (graph_busy||pending||stall_status[1]||stall_status[7]))s_axi_bresp<=2'b10;
      8'h0c:begin end
      default:s_axi_bresp<=2'b10;
     endcase
    end else if(aw[14:8]!=0 || aw[1:0]!=0) s_axi_bresp<=2'b10;
    else case(aw[7:0])
     8'he0:if(!ENABLE_PROFILE_TRACE)s_axi_bresp<=2'b10;
      else if(strobe[0]&&wd[0]&&profile_status[17])s_axi_bresp<=2'b10;
     8'he4:if(!ENABLE_PROFILE_TRACE)s_axi_bresp<=2'b10;
     8'h04: begin
      if(strobe[0]) begin
       if(wd[0]) begin
         if(configurable && mode_requested && mode_owned && !wd[3] && !output_config_bad) pending<=1;
        else s_axi_bresp<=2'b10;
       end
       if(wd[1]) begin if(graph_busy || pending) cancel_pending<=1;end
       if(wd[2]) begin
        if(!done_valid) begin done_sticky<=0;result_clear<=1;end
       end
       if(wd[3]) begin if(configurable && !wd[0]) invalidate_pending<=1;else s_axi_bresp<=2'b10;end
      end
     end
     // Stop admitting PS jobs after any currently accepted job drains.
     8'h08: if(pending || invalidate_pending || result_blocked) s_axi_bresp<=2'b10;
      else if(strobe[0]) begin
       mode_requested<=wd[0];
      end
     8'h10: if(configurable) model_base<=merge(model_base,wd,strobe);else s_axi_bresp<=2'b10;
     8'h14: if(configurable) model_capacity<=merge(model_capacity,wd,strobe);else s_axi_bresp<=2'b10;
     8'h18: if(configurable) workspace_base<=merge(workspace_base,wd,strobe);else s_axi_bresp<=2'b10;
     8'h1c: if(configurable) workspace_capacity<=merge(workspace_capacity,wd,strobe);else s_axi_bresp<=2'b10;
     8'h20: if(configurable) plan_base<=merge(plan_base,wd,strobe);else s_axi_bresp<=2'b10;
     8'h24: if(configurable) plan_capacity<=merge(plan_capacity,wd,strobe);else s_axi_bresp<=2'b10;
     8'h28: if(configurable) frame_id<=merge(frame_id,wd,strobe);else s_axi_bresp<=2'b10;
     8'h2c: if(configurable) generation<=merge(generation,wd,strobe);else s_axi_bresp<=2'b10;
     8'h60: if(configurable) output_addr<=merge(output_addr,wd,strobe);else s_axi_bresp<=2'b10;
     8'h64: if(configurable) output_bytes<=merge(output_bytes,wd,strobe);else s_axi_bresp<=2'b10;
     8'h68: if(configurable) output_dtype<=merge(output_dtype,wd,strobe);else s_axi_bresp<=2'b10;
     8'h7c: if(configurable) input_addr<=merge(input_addr,wd,strobe);else s_axi_bresp<=2'b10;
     8'h80: if(configurable) input_bytes<=merge(input_bytes,wd,strobe);else s_axi_bresp<=2'b10;
     // Kept at the ABI address for current PS/staging clients; no auto engine.
     8'h84: if(strobe[0] && wd[0]) s_axi_bresp<=2'b10;
     default: s_axi_bresp<=2'b10;
    endcase
   end
   if(s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
   if(s_axi_arvalid && s_axi_arready) begin
    s_axi_rvalid<=1;s_axi_rresp<=0;s_axi_rdata<=0;
    if(s_axi_araddr[14:8]==7'd1 && s_axi_araddr[1:0]==0)begin
     case(s_axi_araddr[7:0])
      8'h00:s_axi_rdata<=ENABLE_STALL_DIAG ? 32'h53544c31 : 32'd0; // STL1 selected-operator passive snapshot
      8'h04:s_axi_rdata<=ENABLE_STALL_DIAG ? stall_target : 32'd0;
      8'h08:s_axi_rdata<=0;
      8'h0c:s_axi_rdata<=ENABLE_STALL_DIAG ? {24'd0,stall_select} : 32'd0;
      8'h10:s_axi_rdata<=ENABLE_STALL_DIAG ? stall_data : 32'd0;
      8'h14:s_axi_rdata<=ENABLE_STALL_DIAG ? stall_status : 32'd0;
      8'h18:s_axi_rdata<=ENABLE_STALL_DIAG ? stall_frame : 32'd0;
      8'h1c:s_axi_rdata<=ENABLE_STALL_DIAG ? stall_generation : 32'd0;
      8'h20:s_axi_rdata<=ENABLE_STALL_DIAG ? stall_task : 32'd0;
      8'h24:s_axi_rdata<=ENABLE_STALL_DIAG ? stall_model : 32'd0;
      8'h28:s_axi_rdata<=ENABLE_STALL_DIAG ? stall_index : 32'd0;
      8'h2c:s_axi_rdata<=ENABLE_STALL_DIAG ? stall_fault : 32'd0;
      8'h30:s_axi_rdata<=ENABLE_STALL_DIAG ? 85 : 32'd0;
      default:s_axi_rresp<=2'b10;
     endcase
    end else if(s_axi_araddr[14:8]!=0 || s_axi_araddr[1:0]!=0) s_axi_rresp<=2'b10;
    else case(s_axi_araddr[7:0])
     8'he0:s_axi_rdata<=ENABLE_PROFILE_TRACE ? 32'h50524633 : 32'd0; // PRF3, passive one-shot layer trace
     8'he4:s_axi_rdata<=ENABLE_PROFILE_TRACE ? {20'd0,profile_select} : 32'd0;
     8'he8:s_axi_rdata<=ENABLE_PROFILE_TRACE ? profile_data : 32'd0;
     8'hec:s_axi_rdata<=ENABLE_PROFILE_TRACE ? profile_status : 32'd0;
     8'hf0:s_axi_rdata<=ENABLE_PROFILE_TRACE ? profile_frame : 32'd0;
     8'hf4:s_axi_rdata<=ENABLE_PROFILE_TRACE ? profile_generation : 32'd0;
     8'hf8:s_axi_rdata<=ENABLE_PROFILE_TRACE ? profile_task : 32'd0;
     8'hfc:s_axi_rdata<=DIAGNOSTIC_FEATURES;
     8'hcc:s_axi_rdata<=32'h53545231; // STR1; 0x88 remains camera extension ABI
     8'hd0:s_axi_rdata<=32'h4f505431; // OPT1 source interface revision
     8'hd4:s_axi_rdata<=((PS_PREDECODED ? 32'h0000001f : 32'h00000015)&32'hffffffef) |
         (ENABLE_STALL_DIAG ? 32'h00000010:32'd0);
     // OPT1 bit0: exact fused SiLU; bit1: required PS-predecoded control.
     // Hardware-only bit4: STL1 diagnostics; NOT a new package/plan feature.
     8'hd8:s_axi_rdata<=CLOCK_HZ; // NPU clock configuration; not measured Fmax
     8'hdc:s_axi_rdata<=32'h0000000a; // Supported model IDs 1 and 3.
     8'h8c:s_axi_rdata<=32'h00020410; // R4, W2, 16 beats, 64-bit AXI
     8'h90:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_read_bytes[31:0] : 32'd0;
     8'h94:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_read_bytes[63:32] : 32'd0;
     8'h98:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_write_bytes[31:0] : 32'd0;
     8'h9c:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_write_bytes[63:32] : 32'd0;
     8'ha0:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_read_wait[31:0] : 32'd0;
     8'ha4:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_read_wait[63:32] : 32'd0;
     8'ha8:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_write_wait[31:0] : 32'd0;
     8'hac:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_write_wait[63:32] : 32'd0;
     8'hb0:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_read_bursts : 32'd0;
     8'hb4:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_write_bursts : 32'd0;
     8'hb8:s_axi_rdata<=ENABLE_PERF_COUNTERS ? {22'd0,perf_max_writes,5'd0,perf_max_reads} : 32'd0;
     8'hbc:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_pe_vectors[31:0] : 32'd0;
     8'hc0:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_pe_vectors[63:32] : 32'd0;
     8'hc4:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_pe_wait[31:0] : 32'd0;
     8'hc8:s_axi_rdata<=ENABLE_PERF_COUNTERS ? perf_pe_wait[63:32] : 32'd0;

     8'h00: s_axi_rdata<=32'h4e475031;
     8'h04: s_axi_rdata<={28'd0,invalidate_pending,1'b0,cancel_pending,pending};
     8'h08: s_axi_rdata<={27'd0,pending,graph_busy,1'b1,mode_owned,mode_requested};
     8'h0c: s_axi_rdata<={28'd0,cancel_pending,(last_fault!=0),done_sticky,graph_busy};
     8'h10: s_axi_rdata<=model_base;8'h14:s_axi_rdata<=model_capacity;
     8'h18: s_axi_rdata<=workspace_base;8'h1c:s_axi_rdata<=workspace_capacity;
     8'h20: s_axi_rdata<=plan_base;8'h24:s_axi_rdata<=plan_capacity;
     8'h28: s_axi_rdata<=frame_id;8'h2c:s_axi_rdata<=generation;
     8'h30: s_axi_rdata<={16'd0,last_fault};8'h34:s_axi_rdata<=last_model;
     8'h38: s_axi_rdata<=last_task;8'h3c:s_axi_rdata<=current_op_index;
     8'h40: s_axi_rdata<=last_frame;8'h44:s_axi_rdata<=last_generation;
     8'h48: s_axi_rdata<=last_cycles[31:0];8'h4c:s_axi_rdata<=last_cycles[63:32];
     8'h50: s_axi_rdata<=active_task_id;8'h54:s_axi_rdata<=active_frame_id;8'h58:s_axi_rdata<=active_generation;
     8'h60: s_axi_rdata<=output_addr;8'h64:s_axi_rdata<=output_bytes;
     8'h68: s_axi_rdata<={24'd0,output_dtype};
     8'h6c: s_axi_rdata<=result_output_addr;8'h70:s_axi_rdata<=result_output_bytes;
     8'h74: s_axi_rdata<={24'd0,result_output_dtype};8'h78:s_axi_rdata<={31'd0,result_valid};
     8'h7c: s_axi_rdata<=input_addr;8'h80:s_axi_rdata<=input_bytes;
     8'h84: s_axi_rdata<=0; // removed automatic-camera ARM
     8'h88: s_axi_rdata<=32'd2; // camera graph configuration extension version
     default:s_axi_rresp<=2'b10;
    endcase
   end
  end
 end
endmodule

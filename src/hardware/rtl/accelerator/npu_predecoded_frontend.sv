`timescale 1ns/1ps
// Fixed PS-predecoded package metadata. The PS validates AIPKG3, all CRCs and
// tensor/record contents before publishing immutable model residency. This
// frontend retains the PL range/shape boundary without a package body scan or
// a second package cache. It never authorizes an ordinary legacy image.
module npu_predecoded_frontend (
 input logic clk,rst_n,
 input logic cmd_valid,output logic cmd_ready,
 input logic [31:0] cmd_model_base,cmd_model_capacity,
 input logic [31:0] cmd_workspace_base,cmd_workspace_capacity,
 output logic mem_req_valid,input logic mem_req_ready,
 output logic [31:0] mem_req_addr,
 input logic mem_rsp_valid,output logic mem_rsp_ready,
 input logic [31:0] mem_rsp_data,input logic mem_rsp_fault,
 output logic rsp_valid,input logic rsp_ready,
 output logic [3:0] rsp_fault,
 output wire [31:0] rsp_model_id,rsp_profile,rsp_image_bytes,rsp_workspace_bytes,
 output wire [31:0] rsp_input_id,rsp_output_id,rsp_input_lut_id,
 output logic [159:0] rsp_section_addr,
 output wire [159:0] rsp_section_bytes,
 output logic busy
);
 localparam [3:0] BAD_COMMAND=1,BAD_HEADER=2,BAD_DIRECTORY=4,MEMORY_ERROR=5;
 typedef enum logic [3:0] {IDLE,REQUEST,WAIT_WORD,HEADER_RANGE,CHECK,
  SECTION_SELECT,SECTION_SUM,SECTION_CHECK,HOLD} state_t;
 state_t state;
 logic [31:0] metadata[4:21];
 logic [31:0] base,capacity,workspace_base,workspace_capacity,previous_end;
 logic [4:0] word_index;
 logic [2:0] section_index;
 logic schema_bad;
 logic [31:0] section_offset,section_bytes;
 logic [31:0] section_offset_q,section_bytes_q;
 logic [32:0] image_end,workspace_end,section_end,section_address;
 assign rsp_model_id=metadata[4];assign rsp_profile=metadata[5];
 assign rsp_image_bytes=metadata[6];assign rsp_workspace_bytes=metadata[7];
 assign rsp_input_id=metadata[8];assign rsp_output_id=metadata[9];assign rsp_input_lut_id=metadata[10];
 generate
  for(genvar j=4;j<22;j=j+1)begin:g_metadata
   // Payload has no reset; CHECK is reachable only after all words arrive.
   always_ff @(posedge clk)
    if(rst_n && state==WAIT_WORD && mem_rsp_valid && !mem_rsp_fault && word_index==5'(j))
     metadata[j]<=mem_rsp_data;
  end
  for(genvar j=0;j<5;j=j+1)begin:g_bytes
   assign rsp_section_bytes[j*32+:32]=metadata[13+2*j];
  end
 endgenerate
 always_comb begin
  cmd_ready=rst_n && state==IDLE;busy=state!=IDLE && state!=HOLD;
  rsp_valid=rst_n && state==HOLD;
  mem_req_valid=rst_n && state==REQUEST;
  mem_req_addr=base+32'h400+{25'd0,word_index,2'b0};
  mem_rsp_ready=rst_n && state==WAIT_WORD;
  section_offset=0;section_bytes=0;
  for(integer j=0;j<5;j=j+1)begin
   section_offset=section_offset | (metadata[12+2*j] & {32{section_index==3'(j)}});
   section_bytes=section_bytes | (metadata[13+2*j] & {32{section_index==3'(j)}});
  end
 end
 always_ff @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;base<=0;capacity<=0;workspace_base<=0;workspace_capacity<=0;
   word_index<=0;section_index<=0;previous_end<=4096;schema_bad<=0;
   rsp_fault<=0;rsp_section_addr<=0;
  end else case(state)
   IDLE:if(cmd_valid)begin
    base<=cmd_model_base;capacity<=cmd_model_capacity;
    workspace_base<=cmd_workspace_base;workspace_capacity<=cmd_workspace_capacity;
    word_index<=0;section_index<=0;previous_end<=4096;schema_bad<=0;rsp_fault<=0;
    if(cmd_model_base[11:0]!=0 || cmd_workspace_base[11:0]!=0 ||
       cmd_model_capacity<4096 || cmd_workspace_capacity==0 ||
       ({1'b0,cmd_model_base}+33'h480)>33'h100000000)begin
     rsp_fault<=BAD_COMMAND;state<=HOLD;
    end else state<=REQUEST;
   end
   REQUEST:if(mem_req_ready)state<=WAIT_WORD;
   WAIT_WORD:if(mem_rsp_valid)begin
    // Every accepted request consumes its terminal response before HOLD.
    if(mem_rsp_fault)begin rsp_fault<=MEMORY_ERROR;state<=HOLD;end
    else begin
     case(word_index)
      0:if(mem_rsp_data!=32'h5055504e)schema_bad<=1;
      1:if(mem_rsp_data!=32'h00314552)schema_bad<=1;
      2:if(mem_rsp_data!=1)schema_bad<=1;
      3:if(mem_rsp_data!=128)schema_bad<=1;
      // Descriptor CRC is verified by the PS with the package/plan CRCs.
      31:begin end
      default:if(word_index>=22 && mem_rsp_data!=0)schema_bad<=1;
     endcase
     if(word_index==31)state<=HEADER_RANGE;
     else begin word_index<=word_index+1'b1;state<=REQUEST;end
    end
   end
   HEADER_RANGE:begin
    image_end<={1'b0,base}+{1'b0,metadata[6]};
    workspace_end<={1'b0,workspace_base}+{1'b0,metadata[7]};
    state<=CHECK;
   end
   CHECK:begin
    if(schema_bad || (metadata[4]!=1 && metadata[4]!=3) || metadata[5]!=2 ||
       metadata[6]<4096 || metadata[6][11:0]!=0 || metadata[6]>capacity ||
       metadata[7]==0 || metadata[7][11:0]!=0 || metadata[7]>workspace_capacity ||
       image_end>33'h100000000 || workspace_end>33'h100000000 ||
       ({1'b0,base}<workspace_end && {1'b0,workspace_base}<image_end))begin
     rsp_fault<=BAD_HEADER;state<=HOLD;
    end else if(metadata[15]==0 || metadata[15][6:0]!=0 ||
       metadata[17]==0 || metadata[17][6:0]!=0 || metadata[11]!=(metadata[17]>>7) ||
       metadata[8]>=(metadata[15]>>7) || metadata[9]>=(metadata[15]>>7) ||
       (metadata[10]!=32'hffffffff && metadata[10]>=(metadata[15]>>7)))begin
     rsp_fault<=BAD_DIRECTORY;state<=HOLD;
    end else state<=SECTION_SELECT;
   end
   // Payload registers are consumed only after their owning stage completes.
   SECTION_SELECT:begin
    section_offset_q<=section_offset;section_bytes_q<=section_bytes;
    state<=SECTION_SUM;
   end
   SECTION_SUM:begin
    section_end<={1'b0,section_offset_q}+{1'b0,section_bytes_q};
    section_address<={1'b0,base}+{1'b0,section_offset_q};
    state<=SECTION_CHECK;
   end
   SECTION_CHECK:begin
    if(section_offset_q[11:0]!=0 || section_offset_q<previous_end ||
       section_end>{1'b0,metadata[6]} || section_end[32])begin
     rsp_fault<=BAD_DIRECTORY;state<=HOLD;
    end else begin
     for(integer j=0;j<5;j=j+1)
      if(section_index==3'(j))rsp_section_addr[j*32+:32]<=section_address[31:0];
     previous_end<=section_end[31:0];
     if(section_index==4)state<=HOLD;
     else begin section_index<=section_index+1'b1;state<=SECTION_SELECT;end
    end
   end
   HOLD:if(rsp_ready)state<=IDLE;
   default:begin rsp_fault<=BAD_HEADER;state<=HOLD;end
  endcase
 end
endmodule

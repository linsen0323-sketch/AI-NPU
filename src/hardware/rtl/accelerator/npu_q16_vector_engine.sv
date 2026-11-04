`timescale 1ns/1ps
// Called only after the scalar engine's complete geometry/alias preflight.
// Each 128-element tile is read and checked before its valid output prefix
// is written. No accepted descriptor survives the terminal response.
module npu_q16_vector_engine #(parameter bit EXTERNAL_FUSION=0) (
    input wire clk,rst_n,input wire cmd_valid,output wire cmd_ready,
    input wire [4:0] op,input wire [31:0] count,input wire [31:0] base_a,base_b,base_y,
    input wire [31:0] stride_a,stride_b,input wire [2:0] dtype_a,dtype_b,dtype_y,
    input wire legacy,input wire signed [63:0] multiplier,multiplier_b,
    input wire [6:0] shift,input wire signed [7:0] legacy_shift,
    output wire rsp_valid,input wire rsp_ready,output reg [7:0] rsp_fault,
    output reg [31:0] rsp_completed,
    output wire rd_cmd_valid,input wire rd_cmd_ready,output wire [31:0] rd_cmd_addr,rd_cmd_bytes,
    input wire rd_valid,output wire rd_ready,input wire [63:0] rd_data,input wire [7:0] rd_keep,input wire rd_last,
    input wire rd_rsp_valid,output wire rd_rsp_ready,input wire [3:0] rd_fault,
    output wire wr_cmd_valid,input wire wr_cmd_ready,output wire [31:0] wr_cmd_addr,wr_cmd_bytes,
    output wire wr_valid,input wire wr_ready,output reg [63:0] wr_data,output reg [7:0] wr_keep,output reg wr_last,
    input wire wr_rsp_valid,output wire wr_rsp_ready,input wire [3:0] wr_fault,
    output wire lut_req_valid,input wire lut_req_ready,output wire [1:0] lut_req_kind,output wire [12:0] lut_req_index,
    input wire lut_rsp_valid,output wire lut_rsp_ready,input wire signed [63:0] lut_y0,lut_y1,input wire [3:0] lut_fault,
    input wire fusion_active,fusion_valid,output wire fusion_ready,
    input wire [4:0] fusion_op,input wire [2:0] fusion_dtype,
    input wire signed [63:0] fusion_multiplier,input wire [6:0] fusion_shift,
    input wire signed [31:0] fusion_data,input wire [9:0] fusion_tag,
    output wire fusion_rsp_valid,output wire [31:0] fusion_result,
    output wire [9:0] fusion_rsp_tag,output wire [7:0] fusion_fault
);
    localparam [3:0] IDLE=0,TILE=1,READ_PREP=2,READ_CMD=3,READ_DATA=4,
        COMPUTE_PREP=5,COMPUTE=6,WRITE_PREP=7,WRITE_CMD=8,WRITE_DATA=9,NEXT_TILE=10,RESPONSE=11;
    reg [3:0] state;
    reg [31:0] remaining,a,b,y;
    reg [7:0] tile_count,issued,retired,error_index,write_count;
    reg read_b,read_bad,read_last_seen;
    reg [10:0] load_bytes,store_bytes;
    reg [7:0] load_words,loaded_words,store_words,fetched_words;
    reg [7:0] final_read_keep,final_write_keep;
    reg [7:0] tile_fault;
    wire uses_b=op==4 || op==5;
    wire [1:0] a_size=dtype_a==1 ? 2'd0 : 2'd2;
    wire [1:0] b_size=dtype_b==1 ? 2'd0 : 2'd2;
    wire [1:0] y_size=dtype_y[1:0]-2'd1;
    wire read_broadcast=read_b ? stride_b==0 : stride_a==0;
    wire [1:0] load_size=read_b ? b_size : a_size;
    wire [10:0] next_load_bytes=11'(read_broadcast ? 8'd1 : tile_count)<<load_size;
    wire [10:0] next_store_bytes={3'd0,error_index}<<y_size;
    (* ram_style="block" *) reg [63:0] input_a[0:63],input_b[0:63];
    (* ram_style="block" *) reg [63:0] output_buffer[0:127];
    reg [63:0] a_word,b_word;
    reg [2:0] a_lane,b_lane;
    reg [6:0] lane_tag;
    reg lane_valid,write_valid;
    wire lane_ready;
    wire read_slot_ready=!lane_valid || lane_ready;
    wire [6:0] a_element=stride_a==0 ? 7'd0 : issued[6:0];
    wire [6:0] b_element=stride_b==0 ? 7'd0 : issued[6:0];
    wire [31:0] a_shifted=32'(a_word>>{a_lane,3'b000});
    wire [31:0] b_shifted=32'(b_word>>{b_lane,3'b000});
    wire signed [31:0] lane_a=dtype_a==1 ? {{24{a_shifted[7]}},a_shifted[7:0]} : a_shifted;
    wire signed [31:0] lane_b=dtype_b==1 ? {{24{b_shifted[7]}},b_shifted[7:0]} : b_shifted;
    wire result_valid;
    wire shared_fusion=EXTERNAL_FUSION && fusion_active;
    wire [9:0] pipe_tag;
    wire signed [63:0] result_value;
    wire [6:0] result_tag;
    wire [7:0] result_fault;
    wire [9:0] result_byte={3'd0,result_tag}<<y_size;
    wire [63:0] packed_result=result_value<<{result_byte[2:0],3'b000};
    wire [7:0] result_mask=(8'hff>>(8-(4'd1<<y_size)))<<result_byte[2:0];
    always @(posedge clk) begin
        if (rst_n && state==READ_DATA && rd_valid && rd_ready && loaded_words<load_words) begin
            if (read_b) input_b[loaded_words[5:0]]<=rd_data;
            else input_a[loaded_words[5:0]]<=rd_data;
        end
        if (state==COMPUTE && read_slot_ready && issued<tile_count) begin
            a_word<=input_a[a_element>>(3-a_size)];
            b_word<=input_b[b_element>>(3-b_size)];
        end
        if (rst_n && state==COMPUTE && result_valid && result_fault==0) begin
            for (integer byte_lane=0;byte_lane<8;byte_lane=byte_lane+1)
                if (result_mask[byte_lane]) output_buffer[result_byte[9:3]][byte_lane*8+:8]<=packed_result[byte_lane*8+:8];
        end
        if (state==WRITE_DATA && (!write_valid || wr_ready) && fetched_words<store_words)
            wr_data<=output_buffer[fetched_words[6:0]];
    end
    assign result_tag=pipe_tag[6:0];
    assign fusion_ready=shared_fusion && lane_ready;
    assign fusion_rsp_valid=shared_fusion && result_valid;
    assign fusion_result=result_value[31:0];
    assign fusion_rsp_tag=pipe_tag;
    assign fusion_fault=result_fault;
    npu_q16_vector_pipe #(.TAG_W(10)) u_pipe (
        .clk(clk),.rst_n(rst_n),.op(shared_fusion ? fusion_op : op),.legacy(shared_fusion ? 1'b0 : legacy),.output_dtype(shared_fusion ? fusion_dtype : dtype_y),
        .multiplier(shared_fusion ? fusion_multiplier : multiplier),.multiplier_b(multiplier_b),.shift(shared_fusion ? fusion_shift : shift),.legacy_shift(legacy_shift),
        .in_valid(shared_fusion ? fusion_valid : (lane_valid && state==COMPUTE)),.in_ready(lane_ready),
        .in_a(shared_fusion ? fusion_data : lane_a),.in_b(lane_b),.in_tag(shared_fusion ? fusion_tag : {3'd0,lane_tag}),
        .out_valid(result_valid),.out_value(result_value),.out_tag(pipe_tag),.out_fault(result_fault),
        .lut_req_valid(lut_req_valid),.lut_req_ready(lut_req_ready),.lut_req_kind(lut_req_kind),.lut_req_index(lut_req_index),
        .lut_rsp_valid(lut_rsp_valid),.lut_rsp_ready(lut_rsp_ready),.lut_y0(lut_y0),.lut_y1(lut_y1),.lut_fault(lut_fault));
    assign cmd_ready=rst_n && state==IDLE;
    assign rsp_valid=rst_n && state==RESPONSE;
    assign rd_cmd_valid=rst_n && state==READ_CMD;
    assign rd_cmd_addr=read_b ? b : a;
    assign rd_cmd_bytes={21'd0,load_bytes};
    assign rd_ready=rst_n && state==READ_DATA;
    assign rd_rsp_ready=rst_n && state==READ_DATA;
    assign wr_cmd_valid=rst_n && state==WRITE_CMD;
    assign wr_cmd_addr=y;
    assign wr_cmd_bytes={21'd0,store_bytes};
    assign wr_valid=rst_n && state==WRITE_DATA && write_valid;
    assign wr_rsp_ready=rst_n && state==WRITE_DATA;
    wire read_fire=rd_valid && rd_ready;
    wire read_packet_bad=loaded_words>=load_words ||
        rd_keep!=(loaded_words+8'd1==load_words ? final_read_keep : 8'hff) ||
        rd_last!=(loaded_words+8'd1==load_words);
    always @(posedge clk) begin
        if (!rst_n) begin
            state<=IDLE;rsp_fault<=0;rsp_completed<=0;lane_valid<=0;write_valid<=0;
            issued<=0;retired<=0;fetched_words<=0;loaded_words<=0;
        end else begin
            case (state)
                IDLE: if (cmd_valid) begin
                    remaining<=count;a<=base_a;b<=base_b;y<=base_y;
                    rsp_fault<=0;rsp_completed<=0;state<=TILE;
                end
                TILE: begin
                    tile_count<=remaining>128 ? 8'd128 : remaining[7:0];
                    read_b<=0;tile_fault<=0;state<=READ_PREP;
                end
                READ_PREP: begin
                    load_bytes<=next_load_bytes;load_words<=8'((next_load_bytes+11'd7)>>3);
                    final_read_keep<=next_load_bytes[2:0]==0 ? 8'hff : (8'hff>>(4'd8-{1'b0,next_load_bytes[2:0]}));
                    loaded_words<=0;read_bad<=0;read_last_seen<=0;state<=READ_CMD;
                end
                READ_CMD: if (rd_cmd_ready) state<=READ_DATA;
                READ_DATA: begin
                    if (read_fire) begin
                        loaded_words<=loaded_words+8'd1;
                        read_last_seen<=read_last_seen || rd_last;
                        if (read_packet_bad) read_bad<=1;
                    end
                    if (rd_rsp_valid) begin
                        if (rd_fault!=0 || read_bad || (read_fire && read_packet_bad) ||
                            loaded_words+8'(read_fire)!=load_words || !(read_last_seen || (read_fire && rd_last))) begin
                            rsp_fault<=rd_fault!=0 ? (8'h20|{4'd0,rd_fault}) : 8'h28;state<=RESPONSE;
                        end else if (!read_b && uses_b) begin read_b<=1;state<=READ_PREP;end
                        else state<=COMPUTE_PREP;
                    end
                end
                COMPUTE_PREP: begin
                    issued<=0;retired<=0;lane_valid<=0;error_index<=tile_count;state<=COMPUTE;
                end
                COMPUTE: begin
                    if (read_slot_ready) begin
                        lane_valid<=issued<tile_count;
                        if (issued<tile_count) begin
                            issued<=issued+8'd1;lane_tag<=issued[6:0];
                            a_lane<=3'(a_element<<a_size);b_lane<=3'(b_element<<b_size);
                        end
                    end
                    if (result_valid) begin
                        retired<=retired+8'd1;
                        if (result_fault!=0 && {1'b0,result_tag}<error_index) begin
                            error_index<={1'b0,result_tag};tile_fault<=result_fault;
                        end
                        if (retired+8'd1==tile_count) state<=WRITE_PREP;
                    end
                end
                WRITE_PREP: begin
                    write_count<=error_index;store_bytes<=next_store_bytes;
                    store_words<=8'((next_store_bytes+11'd7)>>3);
                    final_write_keep<=next_store_bytes[2:0]==0 ? 8'hff : (8'hff>>(4'd8-{1'b0,next_store_bytes[2:0]}));
                    fetched_words<=0;write_valid<=0;
                    if (error_index==0) begin rsp_fault<=tile_fault;state<=RESPONSE;end
                    else state<=WRITE_CMD;
                end
                WRITE_CMD: if (wr_cmd_ready) state<=WRITE_DATA;
                WRITE_DATA: begin
                    if (!write_valid || wr_ready) begin
                        write_valid<=fetched_words<store_words;
                        if (fetched_words<store_words) begin
                            fetched_words<=fetched_words+8'd1;
                            wr_last<=fetched_words+8'd1==store_words;
                            wr_keep<=fetched_words+8'd1==store_words ? final_write_keep : 8'hff;
                        end
                    end
                    if (wr_rsp_valid) begin
                        write_valid<=0;
                        if (wr_fault!=0) begin rsp_fault<=8'h20|{4'd0,wr_fault};state<=RESPONSE;end
                        else begin
                            rsp_completed<=rsp_completed+{24'd0,write_count};
                            if (tile_fault!=0) begin rsp_fault<=tile_fault;state<=RESPONSE;end
                            else state<=NEXT_TILE;
                        end
                    end
                end
                NEXT_TILE: begin
                    if (remaining=={24'd0,tile_count}) state<=RESPONSE;
                    else begin
                        remaining<=remaining-{24'd0,tile_count};
                        if (stride_a!=0) a<=a+({24'd0,tile_count}<<a_size);
                        if (stride_b!=0) b<=b+({24'd0,tile_count}<<b_size);
                        y<=y+({24'd0,tile_count}<<y_size);state<=TILE;
                    end
                end
                RESPONSE: if (rsp_ready) state<=IDLE;
                default: state<=state;
            endcase
        end
    end
endmodule

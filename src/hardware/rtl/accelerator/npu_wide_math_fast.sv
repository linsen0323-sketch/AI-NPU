`timescale 1ns/1ps
// Exact signed INT64 arithmetic. Four 17x17 positive DSP products build the
// unsigned 64x64 product in four issues, with sum/join/accumulate stages.
// Two shift stages retain guard/sticky bits; no precision is discarded before
// RNE and signed range checks. Other operation codes return a domain fault.
module npu_wide_math_fast (
 input wire clk,rst_n,input wire req_valid,output wire req_ready,
 input wire [2:0] req_op,input wire signed [63:0] req_a,req_b,input wire [6:0] req_shift,
 output wire rsp_valid,input wire rsp_ready,output reg signed [63:0] rsp_result,output reg [1:0] rsp_fault
);
 typedef enum logic [2:0]{IDLE,MULTIPLY,SHIFT_LOW,SHIFT_HIGH,ROUND,RESPONSE}state_t;
 state_t state;
 reg negative,guard_bit,sticky_bit;
 reg [6:0] shift;
 reg [127:0] magnitude;
 reg [63:0] amag,bmag;
 reg [2:0] issue;
 reg p_valid,s_valid,j_valid;
 reg [1:0] p_tag,s_tag,j_tag;
 (* use_dsp="yes" *) reg [33:0] p0,p1,p2,p3;
 reg [47:0] low_sum,high_sum;
 reg [79:0] joined;
 wire signed [16:0] bpart=$signed({1'b0,bmag[issue[1:0]*16+:16]});
 wire [127:0] contribution=j_tag==0 ? {48'd0,joined} : j_tag==1 ? {32'd0,joined,16'd0} :
                                  j_tag==2 ? {16'd0,joined,32'd0} : {joined,48'd0};
 wire signed [64:0] sum={req_a[63],req_a}+{req_b[63],req_b};
 wire round_up=guard_bit&&(sticky_bit||magnitude[0]);
 wire overflow=(|magnitude[127:64])||
  (negative ? (magnitude[63]&&((|magnitude[62:0])||round_up)) :
              (magnitude[63]||((&magnitude[62:0])&&round_up)));
 wire [63:0] rounded=(negative ? ~magnitude[63:0] : magnitude[63:0])+{63'd0,(negative ? !round_up : round_up)};
 wire [15:0] high_guard,high_sticky;
 assign high_guard[0]=guard_bit;assign high_sticky[0]=sticky_bit;
 generate for(genvar g=1;g<16;g=g+1)begin:g_round
  assign high_guard[g]=magnitude[g*8-1];
  assign high_sticky[g]=sticky_bit||guard_bit||(|magnitude[g*8-2:0]);
 end endgenerate
 function automatic [63:0] abs64(input signed [63:0] value);
  abs64=value[63] ? (~$unsigned(value)+64'd1) : $unsigned(value);
 endfunction
 // Retain the existing service's synchronous reset/handshake convention.
 assign req_ready=state==IDLE;assign rsp_valid=state==RESPONSE;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;negative<=0;guard_bit<=0;sticky_bit<=0;shift<=0;magnitude<=0;amag<=0;bmag<=0;
   issue<=0;p_valid<=0;s_valid<=0;j_valid<=0;p_tag<=0;s_tag<=0;j_tag<=0;
   p0<=0;p1<=0;p2<=0;p3<=0;low_sum<=0;high_sum<=0;joined<=0;
   rsp_result<=0;rsp_fault<=0;
  end else case(state)
   IDLE:if(req_valid)begin
    rsp_result<=0;rsp_fault<=0;negative<=req_a[63];guard_bit<=0;sticky_bit<=0;shift<=req_shift;
    p_valid<=0;s_valid<=0;j_valid<=0;issue<=0;
    case(req_op)
     0:begin state<=RESPONSE;if(sum[64]!=sum[63])rsp_fault<=2;else rsp_result<=sum[63:0];end
     1:begin amag<=abs64(req_a);bmag<=abs64(req_b);negative<=req_a[63]^req_b[63];magnitude<=0;state<=MULTIPLY;end
     2:if(req_shift>64)begin rsp_fault<=1;state<=RESPONSE;end
       else begin magnitude<={64'd0,abs64(req_a)};state<=SHIFT_LOW;end
     default:begin rsp_fault<=1;state<=RESPONSE;end
    endcase
   end
   MULTIPLY:begin
    p_valid<=issue<4;s_valid<=p_valid;j_valid<=s_valid;
    if(issue<4)begin
     p0<=$signed({1'b0,amag[15:0]})*bpart;p1<=$signed({1'b0,amag[31:16]})*bpart;
     p2<=$signed({1'b0,amag[47:32]})*bpart;p3<=$signed({1'b0,amag[63:48]})*bpart;
     p_tag<=issue[1:0];issue<=issue+1'b1;
    end
    if(p_valid)begin low_sum<={16'd0,p0[31:0]}+{p1[31:0],16'd0};high_sum<={16'd0,p2[31:0]}+{p3[31:0],16'd0};s_tag<=p_tag;end
    if(s_valid)begin joined<={32'd0,low_sum}+{high_sum,32'd0};j_tag<=s_tag;end
    if(j_valid)begin magnitude<=magnitude+contribution;if(j_tag==3)state<=SHIFT_LOW;end
   end
   SHIFT_LOW:begin
    magnitude<=magnitude>>shift[2:0];
    guard_bit<=shift[2:0]==0 ? 1'b0 : magnitude[shift[2:0]-1'b1];
    sticky_bit<=shift[2:0]<=1 ? 1'b0 : (|(magnitude[7:0]&((8'd1<<(shift[2:0]-1'b1))-1'b1)));
    state<=SHIFT_HIGH;
   end
   SHIFT_HIGH:begin
    magnitude<=magnitude>>{shift[6:3],3'b000};guard_bit<=high_guard[shift[6:3]];sticky_bit<=high_sticky[shift[6:3]];state<=ROUND;
   end
   ROUND:begin if(overflow)rsp_fault<=2;else rsp_result<=rounded;state<=RESPONSE;end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule

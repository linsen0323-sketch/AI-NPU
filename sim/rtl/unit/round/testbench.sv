`timescale 1ns/1ps
module tb_round_miter;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,in_valid=0;
 reg signed [95:0] in_value=0,wide_value=0;
 reg signed [7:0] in_shift=0;
 reg [15:0] in_tag=0;
 wire old_valid,new_valid,wide_old_valid,wide_new_valid;
 wire signed [7:0] old8,new8,wide_old8,wide_new8;
 wire signed [31:0] old32,new32,wide_old32,wide_new32;
 wire old_overflow,new_overflow,wide_old_overflow,wide_new_overflow;
 wire [15:0] old_tag,new_tag,wide_old_tag,wide_new_tag;
 wire old_busy,new_busy,wide_old_busy,wide_new_busy;
 npu_resnet_round_pipe_before #(.TAG_W(16)) old_narrow(
  .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_value(in_value),.in_shift(in_shift),.in_tag(in_tag),
  .out_valid(old_valid),.out_result8(old8),.out_result32(old32),.out_overflow32(old_overflow),.out_tag(old_tag),.busy(old_busy));
 npu_resnet_round_pipe #(.TAG_W(16),.MAG_W(73)) candidate_narrow(
  .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_value(in_value),.in_shift(in_shift),.in_tag(in_tag),
  .out_valid(new_valid),.out_result8(new8),.out_result32(new32),.out_overflow32(new_overflow),.out_tag(new_tag),.busy(new_busy));
 npu_resnet_round_pipe_before #(.TAG_W(16)) old_wide(
  .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_value(wide_value),.in_shift(in_shift),.in_tag(in_tag),
  .out_valid(wide_old_valid),.out_result8(wide_old8),.out_result32(wide_old32),.out_overflow32(wide_old_overflow),.out_tag(wide_old_tag),.busy(wide_old_busy));
 npu_resnet_round_pipe #(.TAG_W(16)) candidate_default(
  .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_value(wide_value),.in_shift(in_shift),.in_tag(in_tag),
  .out_valid(wide_new_valid),.out_result8(wide_new8),.out_result32(wide_new32),.out_overflow32(wide_new_overflow),.out_tag(wide_new_tag),.busy(wide_new_busy));
 integer checked=0,checked_wide=0,issued=0,cycles=0,resets=0;
 reg [31:0] rng=32'h498175e3;
 function automatic [31:0] random32;
  rng=rng*32'd1664525+32'd1013904223;return rng;
 endfunction
 function automatic signed [95:0] random96;
  return {random32(),random32(),random32()};
 endfunction
 function automatic signed [95:0] extend73(input logic signed [95:0] value);
  return {{23{value[72]}},value[72:0]};
 endfunction
 always @(posedge clk)begin
  #1;cycles++;
  if({old_valid,old_busy}!=={new_valid,new_busy})$fatal(1,"narrow qualifiers cycle=%0d",cycles);
  if({wide_old_valid,wide_old_busy}!=={wide_new_valid,wide_new_busy})$fatal(1,"default qualifiers cycle=%0d",cycles);
  if(old_valid)begin
   if({old8,old32,old_overflow,old_tag}!=={new8,new32,new_overflow,new_tag})
    $fatal(1,"narrow mismatch cycle=%0d tag=%0d old=%h/%h/%b new=%h/%h/%b",cycles,old_tag,old8,old32,old_overflow,new8,new32,new_overflow);
   checked++;
  end
  if(wide_old_valid)begin
   if({wide_old8,wide_old32,wide_old_overflow,wide_old_tag}!=={wide_new8,wide_new32,wide_new_overflow,wide_new_tag})
    $fatal(1,"default mismatch cycle=%0d tag=%0d",cycles,wide_old_tag);
   checked_wide++;
  end
 end
 task automatic send(input logic signed [95:0] value,input integer shift,input bit valid=1);
  @(negedge clk);in_value=extend73(value);wide_value=random96();in_shift=8'(shift);in_valid=valid;in_tag++;
  if(valid)issued++;
 endtask
 task automatic reset_pipeline;
  @(negedge clk);rst_n=0;resets++;
  repeat(2)@(negedge clk);rst_n=1;in_valid=0;
 endtask
 task automatic send_wide(input logic signed [95:0] value,input integer shift);
  @(negedge clk);in_value=extend73(value);wide_value=value;in_shift=8'(shift);in_valid=1;in_tag++;issued++;
 endtask
 reg signed [95:0] value,tie;
 initial begin
  reset_pipeline();
  for(integer shift=-128;shift<=127;shift++)begin
   send(96'sd0,shift);send(96'sd1,shift);send(-96'sd1,shift);
   send(96'sd127,shift);send(-96'sd128,shift);
   send(96'sh00000000000000007fffffff,shift);send(-96'sd2147483648,shift);
   send((96'sd1<<<72)-1,shift);send(-(96'sd1<<<72),shift);
   for(integer bit_index=0;bit_index<73;bit_index++)begin
    value=96'sd1<<<bit_index;
    send(value,shift);send(-value,shift);send(value-1,shift);send(-value+1,shift);
   end
   // Ties, one-unit-below/above ties and alternating retained odd/even bits.
   if(shift>0 && shift<=72)begin
    tie=96'sd1<<<(shift-1);
    send(tie-1,shift);send(tie,shift);send(tie+1,shift);
    send(-tie+1,shift);send(-tie,shift);send(-tie-1,shift);
    send(3*tie,shift);send(-3*tie,shift);send(5*tie,shift);send(-5*tie,shift);
   end
   for(integer j=0;j<64;j++)send(random96(),shift,j%9!=0);
   // The default-width API must retain true signed96 extremes and high bits.
   for(integer bit_index=73;bit_index<96;bit_index++)begin
    value=96'sd1<<<bit_index;
    send_wide(value,shift);send_wide(-value,shift);
    send_wide(value-1,shift);send_wide(-value+1,shift);
   end
   // Exercise a reset with tokens in flight, and restart at the same shift.
   if((shift&15)==0)reset_pipeline();
  end
  // Fully random pipeline bubbles, wide default-mode data and signed73 input.
  for(integer j=0;j<65536;j++)send(random96(),integer'(random32()),j%11!=0);
  @(negedge clk);in_valid=0;
  repeat(8)@(negedge clk);
  if(old_busy||new_busy||wide_old_busy||wide_new_busy)$fatal(1,"pipeline did not drain");
  if(checked<140000 || checked_wide!=checked)$fatal(1,"insufficient comparisons %0d/%0d",checked,checked_wide);
  $display("TEST_PASS round_miter narrow=%0d default96=%0d issued=%0d cycles=%0d resets=%0d shifts=-128..127 seed=498175e3",checked,checked_wide,issued,cycles,resets);
  $finish;
 end
 initial begin #10000000;$fatal(1,"round miter watchdog");end
endmodule

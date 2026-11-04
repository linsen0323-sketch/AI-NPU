`timescale 1ns/1ps
module tb_wbuf_native;
    localparam integer BANKS=32;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0, wr_valid=0, wr_page=0, rd_valid=0, rd_page=0, rsp_ready=1;
    logic [4:0] wr_bank=0;
    logic [6:0] wr_row=0,rd_row=0;
    logic [63:0] wr_data=0;
    logic [7:0] wr_strb=0;
    logic [7:0] rd_tag=0;
    logic [31:0] rd_bank_mask='1;
    wire [3:0] wr_ready,rd_ready,rsp_valid,page_conflict;
    wire [2047:0] rsp_data[4];
    wire [7:0] rsp_tag[4];
    genvar d;
    for(d=0;d<4;d=d+1) begin:g_dut
        npu_banked_buffer #(.BANKS(32),.DATA_W(64),.ROW_W(7),.TAG_W(8),
            .RESERVE_PENDING_READ_PAGE(1),.READ_LATENCY(2),
            .ENABLE_READ_BANK_MASK(d>=2),.USE_NATIVE_WBUF((d%2)==0)) dut(
            .clk,.rst_n,.wr_valid,.wr_ready(wr_ready[d]),.wr_page,.wr_bank,
            .wr_row,.wr_data,.wr_strb,.rd_valid,.rd_ready(rd_ready[d]),
            .rd_page,.rd_row,.rd_tag,.rd_bank_mask,.rsp_valid(rsp_valid[d]),
            .rsp_ready,.rsp_data(rsp_data[d]),.rsp_tag(rsp_tag[d]),
            .page_conflict(page_conflict[d]));
    end
    logic [63:0] memory[2][128][32];
    logic [2047:0] latch_data[2],output_data[2];
    logic latch_valid=0,output_valid=0;
    logic [7:0] latch_tag=0,output_tag=0;
    logic next_output_advance,next_read_advance,expected_conflict;
    integer cycles=0,writes=0,reads=0,responses=0,conflicts=0,stall_cycles=0;
    integer masked_reads=0,zero_writes=0,simultaneous=0;
    integer lane,b,m,n;
    logic [31:0] random_state=32'h08ba51e7;
    function automatic [31:0] prng(input [31:0] value);
        logic [31:0] x;
        begin x=value^(value<<13);x=x^(x>>17);prng=x^(x<<5);end
    endfunction
    function automatic [63:0] pattern(input integer p,input integer r,input integer bank);
        pattern=64'hb579e31ca46802df ^ (64'(p)<<63) ^ (64'(r)*64'h0101010101010101)
            ^ (64'(bank)*64'h1020304050607081);
    endfunction
    // The reference is a byte-addressed image and a two-slot transaction
    // pipeline. Memory is read only on accepted requests and only enabled
    // banks replace latch contents. It never inspects either DUT internally.
    always @(posedge clk) begin
        cycles=cycles+1;
        next_output_advance=!output_valid||rsp_ready;
        next_read_advance=!latch_valid||next_output_advance;
        expected_conflict=rd_valid&&wr_valid&&(rd_page==wr_page);
        for(n=0;n<4;n=n+1) begin
            if(rd_ready[n] !== (rst_n&&next_read_advance))
                $fatal(1,"rd_ready DUT%0d cycle%0d",n,cycles);
            if(wr_ready[n] !== (rst_n&&!expected_conflict))
                $fatal(1,"wr_ready DUT%0d cycle%0d",n,cycles);
            if(page_conflict[n] !== expected_conflict)
                $fatal(1,"page_conflict DUT%0d cycle%0d",n,cycles);
        end
        if(!rst_n) begin
            latch_valid=0;output_valid=0;latch_tag=0;output_tag=0;
        end else begin
            if(output_valid&&rsp_ready)responses=responses+1;
            if(output_valid&&!rsp_ready)stall_cycles=stall_cycles+1;
            if(expected_conflict)conflicts=conflicts+1;
            if(next_output_advance) begin
                output_valid=latch_valid;
                if(latch_valid) begin
                    output_tag=latch_tag;
                    for(m=0;m<2;m=m+1)output_data[m]=latch_data[m];
                end
            end
            if(rd_valid&&next_read_advance) begin
                reads=reads+1;
                if(rd_bank_mask!='1)masked_reads=masked_reads+1;
                latch_tag=rd_tag;
                for(b=0;b<32;b=b+1)begin
                    latch_data[0][b*64+:64]=memory[rd_page][rd_row][b];
                    if(rd_bank_mask[b])latch_data[1][b*64+:64]=memory[rd_page][rd_row][b];
                end
            end
            if(next_read_advance)latch_valid=rd_valid;
            if(wr_valid&&!expected_conflict)begin
                writes=writes+1;
                if(!wr_strb)zero_writes=zero_writes+1;
                if(rd_valid&&next_read_advance)simultaneous=simultaneous+1;
                for(lane=0;lane<8;lane=lane+1)if(wr_strb[lane])
                    memory[wr_page][wr_row][wr_bank][lane*8+:8]=wr_data[lane*8+:8];
            end
        end
        #2;
        for(n=0;n<4;n=n+1)begin
            if(rsp_valid[n] !== output_valid)$fatal(1,"rsp_valid DUT%0d cycle%0d",n,cycles);
            if(output_valid)begin
                if(rsp_tag[n] !== output_tag)$fatal(1,"rsp_tag DUT%0d cycle%0d",n,cycles);
                if(rsp_data[n] !== output_data[n/2])begin
                    for(b=0;b<32;b=b+1)if(rsp_data[n][b*64+:64] !== output_data[n/2][b*64+:64])
                        $display("MISMATCH DUT%0d bank%0d got=%h expected=%h",n,b,
                            rsp_data[n][b*64+:64],output_data[n/2][b*64+:64]);
                    $fatal(1,"rsp_data DUT%0d cycle%0d tag%0d",n,cycles,output_tag);
                end
            end
        end
    end
    task automatic step(input bit w,input bit wp,input integer wb,input integer wa,
        input logic[63:0] wd,input logic[7:0] ws,input bit r,input bit rp,input integer ra,
        input logic[7:0] tag,input bit ready,input logic[31:0] mask);
        @(negedge clk);
        wr_valid=w;wr_page=wp;wr_bank=wb;wr_row=wa;wr_data=wd;wr_strb=ws;
        rd_valid=r;rd_page=rp;rd_row=ra;rd_tag=tag;rsp_ready=ready;rd_bank_mask=mask;
        @(posedge clk);#3;
    endtask
    integer p,r,k,i;
    initial begin
        #200;
        @(negedge clk);rst_n=1;
        // Every row and bank on both pages: catches page, bank, address,
        // half-word and byte-lane wiring rather than relying on RAM init.
        for(p=0;p<2;p=p+1)for(r=0;r<128;r=r+1)for(k=0;k<32;k=k+1)
            step(1,p,k,r,pattern(p,r,k),8'hff,0,0,0,0,1,'1);
        for(p=0;p<2;p=p+1)for(r=0;r<128;r=r+1)
            step(0,0,0,0,0,0,1,p,r,r,1,'1);
        // One-hot strobes on opposite corners; zero strobes, then mixed
        // lanes check that untouched bytes survive repeated partial writes.
        for(i=0;i<8;i=i+1)begin
            step(1,0,0,0,~pattern(0,0,i),8'(1<<i),0,0,0,0,1,'1);
            step(1,1,31,127,~pattern(1,127,i),8'(1<<i),0,0,0,0,1,'1);
        end
        step(1,0,31,127,64'hdeadbeef89abcdef,8'h00,0,0,0,0,1,'1);
        step(1,0,31,127,64'hdeadbeef89abcdef,8'ha5,1,1,127,1,1,'1);
        step(0,0,0,0,0,0,1,0,127,2,1,'1);
        step(0,0,0,0,0,0,1,0,0,3,0,'1);
        step(0,0,0,0,0,0,1,1,127,4,0,'1);
        for(i=0;i<20;i=i+1)
            // Full pipeline holds rsp and pending-read reservation blocks
            // same-page writes even while the pending read is stalled.
            step(1,1,31,127,0,8'hff,1,1,127,5,0,'1);
        step(1,0,31,127,64'h123456789abcdef0,8'h5a,1,1,127,5,1,'1);
        for(i=0;i<5000;i=i+1)begin
            random_state=prng(random_state);
            step(random_state[0],random_state[1],random_state[6:2],random_state[13:7],
                {random_state,~random_state},random_state[21:14],random_state[22],
                random_state[23],random_state[30:24],i,random_state[31],
                i%7==0 ? 32'hffffffff : random_state);
        end
        // Reset empties both valid stages; memory contents must persist.
        @(negedge clk);rst_n=0;rd_valid=0;wr_valid=0;rsp_ready=0;
        repeat(3)@(negedge clk);
        rst_n=1;
        for(p=0;p<2;p=p+1)for(r=0;r<128;r=r+1)
            step(0,0,0,0,0,0,1,p,r,r,1,'1);
        repeat(4)step(0,0,0,0,0,0,0,0,0,0,1,'1);
        if(reads<1000||writes<8192||conflicts<100||stall_cycles<100||masked_reads<100||
            zero_writes<1||simultaneous<100)$fatal(1,"Coverage counters inadequate");
        $display("TEST_PASS cycles=%0d writes=%0d reads=%0d responses=%0d conflicts=%0d stalls=%0d masked_reads=%0d zero_writes=%0d simultaneous=%0d seed=08ba51e7",cycles,writes,reads,responses,conflicts,stall_cycles,masked_reads,zero_writes,simultaneous);
        $finish;
    end
    initial begin #1000000;$fatal(1,"WATCHDOG timeout");end
endmodule

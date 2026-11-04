`timescale 1ns / 1ps

// Source-only regression bench. This revision has NOT been simulated.
// Fixed-coordinate pixel oracle covers small top-edge boxes, global border
// priority, clipping, no-room labels, idle preview and unknown class scores.
module tb_ai_result_overlay;
    localparam integer WIDTH=384, HEIGHT=96, FRAMES=13;
    localparam integer TOTAL=WIDTH*HEIGHT*FRAMES;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0;
    logic enable=0,result_valid=0,mode_detection=0;
    logic [31:0] result_frame_id=0,result_generation=0;
    logic [19:0] result_delay_bcd=0,result_inference_bcd=0;
    logic [15:0] result_fps_bcd=0;
    logic [2:0] result_model_id=3;
    logic [1:0] result_status=0;
    logic [2:0] result_class_id=0;
    logic [6:0] result_score_pct=127;
    logic [3:0] box_count=0;
    logic [87:0] box_xmin=0,box_ymin=0,box_xmax=0,box_ymax=0;
    logic [23:0] box_class_id=0;
    logic [55:0] box_score_pct=0;
    logic [15:0] s_axis_tdata=0;
    logic s_axis_tuser=0,s_axis_tlast=0,s_axis_tvalid=0;
    wire s_axis_tready;
    wire [15:0] m_axis_tdata;
    wire m_axis_tuser,m_axis_tlast,m_axis_tvalid;
    logic m_axis_tready=0;
    logic [31:0] ready_lfsr=32'h17AB569D;
    integer scenario=0,accepted=0,emitted=0,checked_colours=0,stall_cycles=0;
    logic [18:0] expected [0:TOTAL-1];
    logic stalled=0;
    logic [17:0] held_output=0;
    logic [16:0] colour_contract;
    integer input_x=0,input_y=0;
    integer border_checks[0:FRAMES-1];

    ai_result_overlay #(.IMAGE_WIDTH(WIDTH),.IMAGE_HEIGHT(HEIGHT),.BORDER(3)) dut (.*);

    function automatic [15:0] original_pixel(input integer frame,x,y);
        original_pixel={5'h10+frame[4:0],y[5:0]^6'h1A,x[4:0]^5'h15};
    endfunction
    function automatic [15:0] dim_pixel(input logic [15:0] rgb);
        dim_pixel={2'b0,rgb[15:13],2'b0,rgb[10:7],2'b0,rgb[4:2]};
    endfunction
    function automatic in_rect(input integer x,y,x0,y0,x1,y1);
        in_rect=x>=x0 && x<x1 && y>=y0 && y<y1;
    endfunction
    function automatic on_border(input integer x,y,x0,y0,x1,y1);
        on_border=in_rect(x,y,x0,y0,x1,y1) &&
            (x<x0+3 || x>=x1-3 || y<y0+3 || y>=y1-3);
    endfunction
    function automatic [16:0] expected_colour(
        input integer which,x,y,input logic [15:0] original
    );
        logic check_colour,border_pixel;
        logic [15:0] rgb;
        logic [4:0] probe_row;
        integer cell_x,cell_index,glyph_x;
        begin
            check_colour=1;rgb=original;border_pixel=0;
            if (which!=3 && in_rect(x,y,8,8,360,56)) check_colour=0;
            case(which)
                1,5: if (in_rect(x,y,40,48,152,64)) check_colour=0;
                4: if (in_rect(x,y,100,18,212,34)) check_colour=0;
                6: if (in_rect(x,y,272,56,384,72)) check_colour=0;
                default:;
            endcase
            if (which==5 && in_rect(x,y,120,24,232,40)) check_colour=0;
            if ((which==1 || which==5) && on_border(x,y,40,64,220,88)) begin
                border_pixel=1;rgb=16'hFA8A;
            end
            if (which==5 && on_border(x,y,120,40,220,72) && !border_pixel) begin
                border_pixel=1;rgb=16'h57EA;
            end
            if (which==4 && on_border(x,y,100,0,180,18)) begin
                border_pixel=1;rgb=16'hFA8A;
            end
            if (which==6 && on_border(x,y,370,72,384,96)) begin
                border_pixel=1;rgb=16'hFA8A;
            end
            if (which==7 && on_border(x,y,0,0,384,96)) begin
                border_pixel=1;rgb=16'hFFFF;
            end
            if (border_pixel) begin
                check_colour=1;border_checks[which]=border_checks[which]+1;
            end
            // Classifier score 127 remains three '-' strokes in header row 2.
            if (which==2 && in_rect(x,y,232,40,280,56)) begin
                check_colour=1;cell_x=(x-232)&15;rgb=dim_pixel(original);
                if (cell_x<10 && y>=46 && y<48) rgb=16'hFFFF;
            end
            // Independent top/middle stroke probes for CONF 0%, 97%, 100%
            // and the percent glyph. These also distinguish leading blank
            // from the 100% hundreds digit without copying decimal conversion.
            if (which>=10 && x>=232 && x<296 &&
                ((y>=40 && y<42) || (y>=46 && y<48))) begin
                check_colour=1;rgb=dim_pixel(original);probe_row=0;
                cell_index=(x-232)>>4;glyph_x=((x-232)&15)>>1;
                case(cell_index)
                    0: if (which==12) probe_row=5'b00100;
                    1: probe_row=y<42 ? 5'b01110 : which==11 ? 5'b01111 : 5'b10101;
                    2: probe_row=which==11 ? (y<42 ? 5'b11111 : 5'b00100) :
                                                               (y<42 ? 5'b01110 : 5'b10101);
                    3: probe_row=y<42 ? 5'b11001 : 5'b01000;
                    default:;
                endcase
                if (glyph_x<5 && probe_row[4-glyph_x]) rgb=16'hFFFF;
            end
            expected_colour={check_colour,rgb};
        end
    endfunction

    always @(negedge clk) begin
        if (!rst_n) m_axis_tready=0;
        else begin
            ready_lfsr={ready_lfsr[30:0],ready_lfsr[31]^ready_lfsr[21]^ready_lfsr[1]^ready_lfsr[0]};
            m_axis_tready=ready_lfsr[0] || ready_lfsr[4];
        end
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (stalled && (!m_axis_tvalid ||
                {m_axis_tuser,m_axis_tlast,m_axis_tdata}!==held_output))
                $fatal(1,"Overlay changed a stalled output pixel/sideband");
            stalled=m_axis_tvalid && !m_axis_tready;
            if (stalled) begin
                held_output={m_axis_tuser,m_axis_tlast,m_axis_tdata};
                stall_cycles=stall_cycles+1;
            end
            if (s_axis_tvalid && s_axis_tready) begin
                if (accepted>=TOTAL) $fatal(1,"Unexpected extra accepted pixel");
                if (s_axis_tuser) begin input_x=0;input_y=0;end
                colour_contract=expected_colour(scenario,input_x,input_y,s_axis_tdata);
                expected[accepted]={colour_contract[16],s_axis_tuser,s_axis_tlast,colour_contract[15:0]};
                accepted=accepted+1;
                if (s_axis_tlast) begin input_x=0;input_y=input_y+1;end
                else input_x=input_x+1;
            end
            if (m_axis_tvalid && m_axis_tready) begin
                if (emitted>=accepted) $fatal(1,"Output pixel without accepted input");
                if ({m_axis_tuser,m_axis_tlast}!==expected[emitted][17:16])
                    $fatal(1,"Overlay SOF/EOL mismatch at output %0d",emitted);
                if (expected[emitted][18]) begin
                    if (m_axis_tdata!==expected[emitted][15:0])
                        $fatal(1,"Overlay pixel %0d expected %h got %h",emitted,expected[emitted][15:0],m_axis_tdata);
                    checked_colours=checked_colours+1;
                end
                emitted=emitted+1;
            end
        end
    end

    task automatic send_frame(input integer which);
        integer x,y;
        begin
            @(negedge clk);scenario=which;
            enable=(which!=3);result_valid=(which!=0 && which!=8 && which!=11);
            result_status=(which==0 || which==9) ? 0 : 1;
            mode_detection=(which!=2 && which<10);
            result_model_id=(which==2 || which>=10) ? 1 : which==7 ? 4 : 3;
            result_frame_id=which;result_generation=32'h12345678;
            result_delay_bcd=20'h99999;
            result_inference_bcd=20'h00123;result_fps_bcd=16'h0123;
            result_class_id=0;result_score_pct=127;box_count=1;
            case(which)
                10:result_score_pct=0;
                11:result_score_pct=97;
                12:result_score_pct=100;
                default:;
            endcase
            box_xmin=0;box_ymin=0;box_xmax=0;box_ymax=0;
            box_xmin[10:0]=40;box_ymin[10:0]=64;
            box_xmax[10:0]=220;box_ymax[10:0]=88;
            box_class_id=0;box_score_pct=0;box_score_pct[6:0]=97;
            case(which)
                4: begin
                    box_xmin[10:0]=100;box_ymin[10:0]=0;
                    box_xmax[10:0]=180;box_ymax[10:0]=18;
                end
                5: begin
                    box_count=2;box_xmin[21:11]=120;box_ymin[21:11]=40;
                    box_xmax[21:11]=220;box_ymax[21:11]=72;
                    box_class_id[5:3]=1;box_score_pct[13:7]=87;
                end
                6: begin
                    box_xmin[10:0]=370;box_ymin[10:0]=72;
                    box_xmax[10:0]=2047;box_ymax[10:0]=2047;
                end
                7: begin
                    box_xmin[10:0]=0;box_ymin[10:0]=0;
                    box_xmax[10:0]=WIDTH;box_ymax[10:0]=HEIGHT;
                    box_class_id[2:0]=7;
                end
                default:;
            endcase
            for (y=0;y<HEIGHT;y=y+1) begin
                for (x=0;x<WIDTH;x=x+1) begin
                    s_axis_tvalid=1;s_axis_tdata=original_pixel(which,x,y);
                    s_axis_tuser=(x==0 && y==0);s_axis_tlast=(x==WIDTH-1);
                    do @(posedge clk); while (!s_axis_tready);
                    @(negedge clk);
                end
            end
            s_axis_tvalid=0;s_axis_tuser=0;s_axis_tlast=0;
            while (emitted!=accepted) @(negedge clk);
        end
    endtask
    initial begin
        for (integer f=0;f<FRAMES;f=f+1) border_checks[f]=0;
        repeat (5) @(posedge clk);
        @(negedge clk);rst_n=1;
        for (integer f=0;f<FRAMES;f=f+1) send_frame(f);
        if (accepted!=TOTAL || emitted!=TOTAL || stall_cycles==0 || checked_colours==0 ||
            border_checks[1]==0 || border_checks[4]==0 || border_checks[5]==0 ||
            border_checks[6]==0 || border_checks[7]==0)
            $fatal(1,"Overlay coverage/count failure");
        $display("TEST_PASS tb_ai_result_overlay pixels=%0d checked=%0d stalls=%0d",emitted,checked_colours,stall_cycles);
        $finish;
    end
    initial begin
        repeat (1000000) @(posedge clk);
        $fatal(1,"Overlay watchdog timeout");
    end
endmodule

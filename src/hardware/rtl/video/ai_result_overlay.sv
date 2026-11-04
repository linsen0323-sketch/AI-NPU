`timescale 1ns/1ps
// Synthesizable matched-frame AXIS compositor. Testbench belongs ONLY in
// verification/tb_ai_result_overlay.sv, never in this RTL source file.
// Upstream owns frame/result matching and holds metadata through the input EOF.
// Seven registered stages: input/metadata, geometry, box selection, character,
// glyph, colour, composition. Only geometry is replicated for eight boxes;
// one selected box owns the shared character/glyph/colour path. Header has its
// own renderer; every box border has priority over labels and the header.
// RGB/SOF/EOL/valid advance together; output
// backpressure freezes every stage. Steady-state throughput is one pixel/clk.
// Scores 101..127 mean unavailable. Classifier logits are not probabilities.
module ai_result_overlay #(
    parameter integer IMAGE_WIDTH=1280,
    parameter integer IMAGE_HEIGHT=720,
    parameter integer BORDER=3
) (
    input wire clk, rst_n, enable, result_valid, mode_detection,
    // Legacy identity/delay inputs remain connected for source compatibility;
    // frame matching is enforced upstream, and the header uses NPU ms below.
    input wire [31:0] result_frame_id, result_generation,
    input wire [19:0] result_delay_bcd,
    input wire [2:0] result_model_id,
    input wire [19:0] result_inference_bcd,
    input wire [15:0] result_fps_bcd,
    input wire [1:0] result_status,
    input wire [2:0] result_class_id,
    input wire [6:0] result_score_pct,
    input wire [3:0] box_count,
    input wire [87:0] box_xmin, box_ymin, box_xmax, box_ymax,
    input wire [23:0] box_class_id,
    input wire [55:0] box_score_pct,
    input wire [15:0] s_axis_tdata,
    input wire s_axis_tuser, s_axis_tlast, s_axis_tvalid,
    output wire s_axis_tready,
    output reg [15:0] m_axis_tdata,
    output reg m_axis_tuser, m_axis_tlast, m_axis_tvalid,
    input wire m_axis_tready
);
    localparam integer CELL=16, HEADER_X=8, HEADER_Y=8;
    localparam integer HEADER_WIDTH=22*CELL, LABEL_WIDTH=7*CELL;
    reg [10:0] pixel_x, pixel_y;
    wire [10:0] active_x=s_axis_tuser ? 11'd0 : pixel_x;
    wire [10:0] active_y=s_axis_tuser ? 11'd0 : pixel_y;
    wire advance=!m_axis_tvalid || m_axis_tready;
    assign s_axis_tready=advance;

    reg [5:0] valid_pipe, sof_pipe, eol_pipe;
    reg [15:0] rgb_pipe [0:5];
    reg [10:0] input_x, input_y;

    // Sample immutable frame metadata at the accepted SOF. Only stage 1 reads
    // these registers. When consecutive frames touch, the previous last pixel
    // leaves stage 0 on the same edge that captures the next frame's metadata;
    // subsequent stages already carry their own resolved per-pixel fields.
    reg frame_osd_active, frame_active, frame_detection;
    reg [2:0] frame_model, header_model1;
    reg [1:0] frame_status, header_status1;
    reg [19:0] frame_inference_bcd, header_inference1;
    reg [15:0] frame_fps_bcd, header_fps1;
    reg [2:0] frame_class;
    reg [6:0] frame_score;
    reg [3:0] frame_boxes;
    reg [87:0] frame_xmin, frame_ymin, frame_xmax, frame_ymax;
    reg [23:0] frame_box_class;
    reg [55:0] frame_box_score;

    reg header_hit1, header_detection1, header_result1;
    reg [1:0] header_row1;
    reg [4:0] header_cell1;
    reg [2:0] header_gx1, header_gy1, header_class1;
    reg [6:0] header_score1;
    reg [3:0] header_boxes1;
    reg header_hit2, header_hit3, header_hit4, header_hit5;
    reg [2:0] header_gx2, header_gy2, header_gx3, header_gy3;
    reg [7:0] header_character2;
    reg [34:0] header_glyph3;
    reg [15:0] header_rgb4, header_rgb5;
    wire [10:0] header_dx=input_x-11'd8;
    wire [10:0] header_dy=input_y-11'd8;

    reg [7:0] border1, label1;
    reg [2:0] box_cell1 [0:7];
    reg [2:0] box_gx1 [0:7], box_gy1 [0:7];
    reg [2:0] box_id1 [0:7];
    reg [6:0] box_score1 [0:7];
    // Select among all borders first, then among labels. A lower-index label
    // must never cover the edge of another box.
    wire [7:0] box_priority1=(|border1) ? border1 : label1;
    wire [7:0] box_hit1=border1 | label1;
    wire [7:0] box_choose1;
    reg selected_label;
    reg [2:0] selected_cell,selected_gx,selected_gy,selected_id;
    reg [6:0] selected_score;
    reg box_hit2,box_hit3,box_hit4,box_hit5;
    reg box_label2,box_label3,box_label4,box_label5;
    reg [2:0] box_cell2,box_gx2,box_gy2,box_id2;
    reg [6:0] box_score2;
    reg [2:0] box_gx3,box_gy3,box_id3,box_gx4,box_gy4,box_id4;
    reg [7:0] box_character3;
    reg [34:0] box_glyph4;
    reg [15:0] box_rgb5;
    // The lowest matching index wins within the border or label priority tier.
    // Select metadata BEFORE decimal conversion and the font ROM; selecting
    // after rendering would infer eight complete renderers again.
    always @* begin
        selected_label=0;selected_cell=0;selected_gx=0;selected_gy=0;
        selected_id=0;selected_score=0;
        for(integer b=0;b<8;b=b+1)begin
            selected_label=selected_label|(label1[b]&!border1[b]&box_choose1[b]);
            selected_cell=selected_cell|(box_cell1[b]&{3{box_choose1[b]}});
            selected_gx=selected_gx|(box_gx1[b]&{3{box_choose1[b]}});
            selected_gy=selected_gy|(box_gy1[b]&{3{box_choose1[b]}});
            selected_id=selected_id|(box_id1[b]&{3{box_choose1[b]}});
            selected_score=selected_score|(box_score1[b]&{7{box_choose1[b]}});
        end
    end

    function automatic [34:0] glyph(input [7:0] c);
        case (c)
            "0": glyph={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
            "1": glyph={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            "2": glyph={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
            "3": glyph={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
            "4": glyph={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
            "5": glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
            "6": glyph={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
            "7": glyph={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
            "8": glyph={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
            "9": glyph={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
            "A": glyph={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            "B": glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
            "C": glyph={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
            "D": glyph={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
            "E": glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
            "F": glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
            "G": glyph={5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111};
            "I": glyph={5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            "L": glyph={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
            "M": glyph={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
            "N": glyph={5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
            "O": glyph={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "P": glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
            "R": glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
            "S": glyph={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
            "T": glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
            "U": glyph={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "W": glyph={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
            "%": glyph={5'b11001,5'b11010,5'b00100,5'b01000,5'b10110,5'b00110,5'b00000};
            ":": glyph={5'b00000,5'b00100,5'b00100,5'b00000,5'b00100,5'b00100,5'b00000};
            "-": glyph={5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
            ".": glyph={5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00100,5'b00100};
            default: glyph=35'd0;
        endcase
    endfunction
    function automatic [7:0] class_char(input [2:0] id,input bit second);
        case (id)
            0: class_char=second ? "R" : "C";
            1: class_char=second ? "N" : "I";
            2: class_char=second ? "S" : "P";
            3: class_char=second ? "A" : "P";
            4: class_char=second ? "S" : "R";
            5: class_char=second ? "C" : "S";
            default: class_char="-";
        endcase
    endfunction
    function automatic [7:0] score_char(input [6:0] score,input [1:0] digit);
        reg [3:0] tens;
        reg [6:0] ones;
        begin
            // Bounded 0..100 decimal conversion. Avoid integer-width divide
            // and remainder hardware in the per-pixel character path.
            tens=0; ones=0;
            if (score!=100) begin
                if      (score>=90) begin tens=9; ones=score-7'd90; end
                else if (score>=80) begin tens=8; ones=score-7'd80; end
                else if (score>=70) begin tens=7; ones=score-7'd70; end
                else if (score>=60) begin tens=6; ones=score-7'd60; end
                else if (score>=50) begin tens=5; ones=score-7'd50; end
                else if (score>=40) begin tens=4; ones=score-7'd40; end
                else if (score>=30) begin tens=3; ones=score-7'd30; end
                else if (score>=20) begin tens=2; ones=score-7'd20; end
                else if (score>=10) begin tens=1; ones=score-7'd10; end
                else ones=score;
            end
            if (score>100) score_char="-";
            else case (digit)
                0: score_char=score==100 ? "1" : " ";
                1: score_char=8'd48+{4'd0,tens};
                default: score_char=8'd48+{1'b0,ones};
            endcase
        end
    endfunction
    function automatic [15:0] class_color(input [2:0] id);
        case(id)
            0: class_color=16'hfa8a;
            1: class_color=16'h57ea;
            2: class_color=16'h551f;
            3: class_color=16'hffea;
            4: class_color=16'hfa9f;
            5: class_color=16'h57ff;
            default: class_color=16'hffff;
        endcase
    endfunction
    function automatic glyph_dot(input [34:0] bits,input [2:0] gx,input [2:0] gy);
        reg [4:0] row_bits;
        begin
            // Two small muxes instead of integer arithmetic and a variable
            // 35-bit shift following the glyph ROM in the same cycle.
            case (gy)
                0: row_bits=bits[34:30]; 1: row_bits=bits[29:25];
                2: row_bits=bits[24:20]; 3: row_bits=bits[19:15];
                4: row_bits=bits[14:10]; 5: row_bits=bits[9:5];
                6: row_bits=bits[4:0]; default: row_bits=0;
            endcase
            case (gx)
                0: glyph_dot=row_bits[4]; 1: glyph_dot=row_bits[3];
                2: glyph_dot=row_bits[2]; 3: glyph_dot=row_bits[1];
                4: glyph_dot=row_bits[0]; default: glyph_dot=0;
            endcase
        end
    endfunction
    function automatic [15:0] dim(input [15:0] rgb);
        dim={2'b0,rgb[15:13],2'b0,rgb[10:7],2'b0,rgb[4:2]};
    endfunction

    function automatic [7:0] bcd_char(input [3:0] digit);
        bcd_char=digit<=9 ? 8'd48+{4'd0,digit} : "-";
    endfunction
    function automatic [7:0] header_char(
        input [4:0] column, input [1:0] row,
        input [2:0] model, input [1:0] status,
        input valid_result, detection, input [3:0] count,
        input [2:0] id, input [6:0] score,
        input [19:0] inference_bcd, input [15:0] fps_bcd
    );
        begin
            header_char=" ";
            case (row)
                0: begin
                    case (column)
                        0:header_char="M"; 1:header_char="O"; 2:header_char="D";
                        3:header_char="E"; 4:header_char="L"; default:;
                    endcase
                    case (model)
                        1: case (column)
                            6:header_char="R";7:header_char="E";8:header_char="S";9:header_char="N";
                            10:header_char="E";11:header_char="T";12:header_char="1";13:header_char="8";
                            default:;
                        endcase
                        3: case (column)
                            6:header_char="N";7:header_char="E";8:header_char="U";9:header_char="6";default:;
                        endcase
                        4: case (column)
                            6:header_char="C";7:header_char="O";8:header_char="C";
                            9:header_char="O";10:header_char="8";11:header_char="0";default:;
                        endcase
                        default: if (column==6) header_char="-";
                    endcase
                    case (status)
                        0: case(column) 16:header_char="I";17:header_char="D";18:header_char="L";19:header_char="E";default:;endcase
                        1: case(column) 16:header_char="R";17:header_char="U";18:header_char="N";default:;endcase
                        2: case(column) 16:header_char="L";17:header_char="O";18:header_char="A";19:header_char="D";default:;endcase
                        3: case(column) 16:header_char="E";17:header_char="R";18:header_char="R";default:;endcase
                    endcase
                end
                1: case (column)
                    0:header_char="N";1:header_char="P";2:header_char="U";
                    4:header_char=bcd_char(inference_bcd[19:16]);
                    5:header_char=bcd_char(inference_bcd[15:12]);
                    6:header_char=bcd_char(inference_bcd[11:8]);
                    7:header_char=bcd_char(inference_bcd[7:4]);
                    8:header_char=bcd_char(inference_bcd[3:0]);
                    9:header_char="M";10:header_char="S";
                    12:header_char="F";13:header_char="P";14:header_char="S";
                    16:header_char=bcd_char(fps_bcd[15:12]);
                    17:header_char=bcd_char(fps_bcd[11:8]);18:header_char=".";
                    19:header_char=bcd_char(fps_bcd[7:4]);
                    20:header_char=bcd_char(fps_bcd[3:0]);default:;
                endcase
                2: if (valid_result) begin
                    if (detection) case (column)
                        0:header_char="D";1:header_char="E";2:header_char="T";
                        4:header_char=8'd48+{4'd0,(count>8 ? 4'd8 : count)};default:;
                    endcase
                    else case (column)
                        0:header_char="C";1:header_char="L";2:header_char="A";
                        3:header_char="S";4:header_char="S";
                        6:header_char=class_char(id,0);7:header_char=class_char(id,1);
                        9:header_char="C";10:header_char="O";11:header_char="N";12:header_char="F";
                        14:header_char=score_char(score,0);15:header_char=score_char(score,1);
                        16:header_char=score_char(score,2);17:header_char="%";default:;
                    endcase
                end else if (status==1) case (column)
                    0:header_char="W";1:header_char="A";2:header_char="I";3:header_char="T";
                    5:header_char="R";6:header_char="E";7:header_char="S";
                    8:header_char="U";9:header_char="L";10:header_char="T";default:;
                endcase
                default:;
            endcase
        end
    endfunction

    // Each box is evaluated in parallel. All geometry is 11/12-bit unsigned,
    // including extensions before +BORDER/+LABEL_WIDTH to avoid overflow.
    generate for (genvar b=0;b<8;b=b+1) begin : g_box
        localparam [7:0] LOWER_MASK=(8'h01 << b)-8'h01;
        localparam [11:0] BORDER_EXT=BORDER;
        localparam [11:0] LABEL_EXT=LABEL_WIDTH, CELL_EXT=CELL;
        localparam [10:0] RIGHT_EDGE=IMAGE_WIDTH, BOTTOM_EDGE=IMAGE_HEIGHT;
        localparam [10:0] LABEL_MAX_X=IMAGE_WIDTH>LABEL_WIDTH ? IMAGE_WIDTH-LABEL_WIDTH : 0;
        localparam [10:0] LABEL_MAX_Y=IMAGE_HEIGHT>CELL ? IMAGE_HEIGHT-CELL : 0;
        localparam [3:0] BOX_INDEX=b;
        wire [10:0] bx0=frame_xmin[b*11+:11], by0=frame_ymin[b*11+:11];
        wire [10:0] bx1=frame_xmax[b*11+:11]>RIGHT_EDGE ? RIGHT_EDGE : frame_xmax[b*11+:11];
        wire [10:0] by1=frame_ymax[b*11+:11]>BOTTOM_EDGE ? BOTTOM_EDGE : frame_ymax[b*11+:11];
        wire label_above=by0>=11'd16;
        wire label_below={1'b0,by1}+CELL_EXT<={1'b0,BOTTOM_EDGE};
        wire label_right={1'b0,bx1}+LABEL_EXT<={1'b0,RIGHT_EDGE};
        wire label_left={1'b0,bx0}>=LABEL_EXT;
        wire label_fits=IMAGE_WIDTH>=LABEL_WIDTH && IMAGE_HEIGHT>=CELL &&
            (label_above || label_below || label_right || label_left);
        // Labels stay outside the box. If no side has room, keep all four
        // borders and omit the label instead of painting over the rectangle.
        wire [10:0] label_x=(label_above || label_below) ?
            (bx0>LABEL_MAX_X ? LABEL_MAX_X : bx0) :
            (label_right ? bx1 : bx0-11'd112);
        wire [10:0] label_y=label_above ? by0-11'd16 : label_below ? by1 :
            (by0>LABEL_MAX_Y ? LABEL_MAX_Y : by0);
        // Reuse the local-coordinate subtractors for both label bounds.
        // The extra bit keeps a negative difference above every valid label
        // extent instead of wrapping back into a small in-range coordinate.
        wire [11:0] dx={1'b0,input_x}-{1'b0,label_x};
        wire [11:0] dy={1'b0,input_y}-{1'b0,label_y};
        wire valid_box=frame_active && frame_detection && BOX_INDEX<frame_boxes && bx0<bx1 && by0<by1;
        assign box_choose1[b]=box_priority1[b] && !(|(box_priority1 & LOWER_MASK));
        always @(posedge clk) begin
            if (rst_n && advance) begin
                // Stage 1: independent region tests and local coordinates.
                border1[b]<=valid_box && input_x>=bx0 && input_x<bx1 && input_y>=by0 && input_y<by1 &&
                    ({1'b0,input_x}<{1'b0,bx0}+BORDER_EXT || {1'b0,input_x}+BORDER_EXT>={1'b0,bx1} ||
                     {1'b0,input_y}<{1'b0,by0}+BORDER_EXT || {1'b0,input_y}+BORDER_EXT>={1'b0,by1});
                label1[b]<=valid_box && label_fits && dx<LABEL_EXT && dy<CELL_EXT;
                box_cell1[b]<=dx[6:4]; box_gx1[b]<=dx[3:1]; box_gy1[b]<=dy[3:1];
                box_id1[b]<=frame_box_class[b*3+:3]; box_score1[b]<=frame_box_score[b*7+:7];
            end
        end
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            pixel_x<=0;pixel_y<=0;m_axis_tvalid<=0;m_axis_tdata<=0;m_axis_tuser<=0;m_axis_tlast<=0;
            valid_pipe<=0; sof_pipe<=0; eol_pipe<=0;
            frame_osd_active<=0; frame_active<=0; frame_detection<=0;
            frame_model<=0; frame_status<=0;
            frame_class<=7; frame_score<=127; frame_boxes<=0;
            frame_inference_bcd<=0; frame_fps_bcd<=0;
            frame_xmin<=0; frame_ymin<=0; frame_xmax<=0; frame_ymax<=0; frame_box_class<=0; frame_box_score<=0;
        end else if (advance) begin
            valid_pipe<={valid_pipe[4:0],s_axis_tvalid};
            sof_pipe<={sof_pipe[4:0],s_axis_tuser}; eol_pipe<={eol_pipe[4:0],s_axis_tlast};
            rgb_pipe[0]<=s_axis_tdata;
            for (integer p=1;p<6;p=p+1) rgb_pipe[p]<=rgb_pipe[p-1];
            // Stage 0: input capture; pixel coordinates advance only on fire.
            if (s_axis_tvalid) begin
                input_x<=active_x; input_y<=active_y;
                if (s_axis_tuser) begin
                    frame_osd_active<=enable;
                    frame_active<=enable && result_valid && result_status==2'd1;
                    frame_detection<=mode_detection;
                    frame_model<=result_model_id; frame_status<=result_status;
                    frame_inference_bcd<=result_status==2'd1 ? result_inference_bcd : 20'd0;
                    frame_fps_bcd<=result_status==2'd1 ? result_fps_bcd : 16'd0;
                    frame_class<=result_class_id; frame_score<=result_score_pct; frame_boxes<=box_count;
                    frame_xmin<=box_xmin; frame_ymin<=box_ymin; frame_xmax<=box_xmax; frame_ymax<=box_ymax;
                    frame_box_class<=box_class_id; frame_box_score<=box_score_pct;
                end
                if (s_axis_tlast) begin pixel_x<=0;pixel_y<=active_y+1'b1;end
                else begin pixel_x<=active_x+1'b1;pixel_y<=active_y;end
            end
            // Stage 1: header geometry and the metadata needed by its renderer.
            header_hit1<=frame_osd_active && input_x>=HEADER_X && input_x<HEADER_X+HEADER_WIDTH &&
                input_y>=HEADER_Y && input_y<HEADER_Y+3*CELL;
            header_row1<=header_dy[5:4]; header_cell1<=header_dx[8:4];
            header_gx1<=header_dx[3:1]; header_gy1<=header_dy[3:1];
            header_detection1<=frame_detection; header_class1<=frame_class; header_score1<=frame_score;
            header_boxes1<=frame_boxes;
            // Retain the last real ResNet classifier summary during RUN even
            // after its original picture expires into live preview. Geometry
            // continues to use only the strictly matched frame_active above.
            header_result1<=frame_active || (frame_status==2'd1 && frame_model==3'd1 &&
                !frame_detection && frame_score<=7'd100);
            header_model1<=frame_model; header_status1<=frame_status;
            header_inference1<=frame_inference_bcd; header_fps1<=frame_fps_bcd;
            // Stages 2..4: isolate character selection, ROM and glyph-dot mux.
            header_character2<=header_char(header_cell1,header_row1,header_model1,header_status1,
                header_result1,header_detection1,header_boxes1,header_class1,header_score1,
                header_inference1,header_fps1);
            header_hit2<=header_hit1; header_gx2<=header_gx1; header_gy2<=header_gy1;
            header_glyph3<=glyph(header_character2);
            header_hit3<=header_hit2; header_gx3<=header_gx2; header_gy3<=header_gy2;
            header_hit4<=header_hit3;
            header_rgb4<=glyph_dot(header_glyph3,header_gx3,header_gy3) ? 16'hffff : dim(rgb_pipe[3]);
            header_hit5<=header_hit4;header_rgb5<=header_rgb4;
            // Stage 2: priority and a narrow one-hot metadata mux only.
            box_hit2<=|box_hit1;box_label2<=selected_label;
            box_cell2<=selected_cell;box_id2<=selected_id;box_score2<=selected_score;
            box_gx2<=selected_gx;box_gy2<=selected_gy;
            // Stage 3: a single class/decimal character selection path.
            case(box_cell2)
                0:box_character3<=class_char(box_id2,0);
                1:box_character3<=class_char(box_id2,1);
                3:box_character3<=score_char(box_score2,0);
                4:box_character3<=score_char(box_score2,1);
                5:box_character3<=score_char(box_score2,2);
                6:box_character3<="%";default:box_character3<=" ";
            endcase
            box_hit3<=box_hit2;box_label3<=box_label2;box_id3<=box_id2;
            box_gx3<=box_gx2;box_gy3<=box_gy2;
            // Stage 4: one shared font ROM, isolated from the glyph-dot mux.
            box_glyph4<=glyph(box_character3);
            box_hit4<=box_hit3;box_label4<=box_label3;box_id4<=box_id3;
            box_gx4<=box_gx3;box_gy4<=box_gy3;
            // Stage 5: all borders already won over every label in stage 2.
            box_hit5<=box_hit4;box_label5<=box_label4;
            box_rgb5<=box_label4 ?
                (glyph_dot(box_glyph4,box_gx4,box_gy4) ? 16'hffff : dim(rgb_pipe[4])) :
                class_color(box_id4);
            // Stage 6: preserve every border, even through the header region.
            m_axis_tvalid<=valid_pipe[5]; m_axis_tuser<=sof_pipe[5]; m_axis_tlast<=eol_pipe[5];
            m_axis_tdata<=box_hit5 && !box_label5 ? box_rgb5 :
                header_hit5 ? header_rgb5 : (box_hit5 ? box_rgb5 : rgb_pipe[5]);
        end
    end
endmodule

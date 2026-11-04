// Two pages of simple-dual-port banks. The default WBUF organization is
// 32 x (512 x 64), with 256 rows in each page: 128 KiB, 2048 bits/read.
// A write loads one 64-bit bank. A read fetches all banks at the same row.
// The output latch and optional native output register hold data under
// backpressure. There is no fabric read-after-write forwarding.
// Page ownership is external (npu_tile_lease). Read wins simultaneous
// same-page access; the writer must retain its request until wr_ready.
module npu_banked_buffer #(
    parameter integer BANKS = 32,
    parameter integer DATA_W = 64,
    parameter integer ROW_W = 8,
    parameter integer TAG_W = 96,
    parameter integer BANK_W = (BANKS > 1) ? $clog2(BANKS) : 1,
    parameter bit RESERVE_PENDING_READ_PAGE = 0,
    parameter integer READ_LATENCY = 1,
    parameter bit ENABLE_READ_BANK_MASK = 1'b0,
    // Keep XPM available for other configurations and direct equivalence tests.
    parameter bit USE_NATIVE_WBUF = 1'b1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic wr_valid,
    output logic wr_ready,
    input  logic wr_page,
    input  logic [BANK_W-1:0] wr_bank,
    input  logic [ROW_W-1:0] wr_row,
    input  logic [DATA_W-1:0] wr_data,
    input  logic [DATA_W/8-1:0] wr_strb,
    input  logic rd_valid,
    output logic rd_ready,
    input  logic rd_page,
    input  logic [ROW_W-1:0] rd_row,
    input  logic [TAG_W-1:0] rd_tag,
    input  logic [BANKS-1:0] rd_bank_mask,
    output logic rsp_valid,
    input  logic rsp_ready,
    output logic [BANKS*DATA_W-1:0] rsp_data,
    output logic [TAG_W-1:0] rsp_tag,
    output logic page_conflict
);
    localparam integer BYTE_LANES = DATA_W / 8;
    localparam longint unsigned BANK_BITS = DATA_W * (64'd1 << (ROW_W+1));

    // XPM supports byte writes for integer multiples of eight. Keep invalid
    // parameter combinations explicit rather than silently dropping bytes.
    // These checks describe the supported wrapper range; they add no datapath.
    initial begin
        if (BANKS < 1 || BANK_W < ((BANKS > 1) ? $clog2(BANKS) : 1))
            $fatal(1,"npu_banked_buffer: BANKS/BANK_W cannot address every bank");
        if (DATA_W < 8 || DATA_W > 4608 || DATA_W % 8 != 0)
            $fatal(1,"npu_banked_buffer: DATA_W must be a multiple of 8 in [8,4608]");
        if (ROW_W < 1 || ROW_W > 19 || BANK_BITS > 150994944 || TAG_W < 1)
            $fatal(1,"npu_banked_buffer: unsupported address, memory or tag size");
        if (READ_LATENCY < 1 || READ_LATENCY > 2)
            $fatal(1,"npu_banked_buffer: READ_LATENCY must be 1 or 2");
    end

    wire read_fire = rd_valid && rd_ready;
    wire write_fire = wr_valid && wr_ready;
    wire [ROW_W:0] read_address = {rd_page,rd_row};
    wire [ROW_W:0] write_address = {wr_page,wr_row};
    logic read_valid;
    logic [TAG_W-1:0] read_tag;
    wire output_advance = !rsp_valid || rsp_ready;
    wire read_advance = READ_LATENCY == 1 ? output_advance : !read_valid || output_advance;
    assign rd_ready = rst_n && read_advance;
    wire read_page_owned = rd_valid && (RESERVE_PENDING_READ_PAGE || rd_ready);
    assign page_conflict = read_page_owned && wr_valid && (rd_page == wr_page);
    assign wr_ready = rst_n && (wr_bank < BANKS) && !page_conflict;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_valid <= 1'b0;
            rsp_tag <= '0;
            read_valid <= 1'b0;
            read_tag <= '0;
        end else if (READ_LATENCY == 1) begin
            if (output_advance) begin
                rsp_valid <= rd_valid;
                if (rd_valid) rsp_tag <= rd_tag;
            end
        end else begin
            if (read_advance) begin
                read_valid <= rd_valid;
                if (rd_valid) read_tag <= rd_tag;
            end
            if (output_advance) begin
                rsp_valid <= read_valid;
                if (read_valid) rsp_tag <= read_tag;
            end
        end
    end
    genvar b;
    generate for (b=0; b<BANKS; b=b+1) begin : g_bank
        wire bank_write_fire = write_fire && (wr_bank == b);
        wire [BYTE_LANES-1:0] bank_byte_we = wr_strb & {BYTE_LANES{bank_write_fire}};

        if (USE_NATIVE_WBUF && BANKS == 32 && DATA_W == 64 && ROW_W == 7 &&
            READ_LATENCY == 2) begin : g_native_wbuf
            // Production WBUF: two 128-row pages in one RAMB36E1 per bank,
            // exactly as in the XPM implementation. The unused ninth word
            // word address bit is zero; SDP x72 addresses occupy [14:6].
            // Tie unused physical address pins high (UG473, page 32).
            // Data uses the 64 regular bits, with eight native byte enables.
            // UG473 Table 1-15 maps low/high halves to A/B data pins.
            // In SDP both DO*_REG values must agree (UG953). REGCEAREGCE
            // advances all 64 output bits independently of the read latch.
            // READ_FIRST is legal for SDP. Its collision behavior is unused:
            // page arbitration forbids accepted same-page reads and writes.
            RAMB36E1 #(
                .RAM_MODE("SDP"),
                .READ_WIDTH_A(72),
                .READ_WIDTH_B(0),
                .WRITE_WIDTH_A(0),
                .WRITE_WIDTH_B(72),
                .DOA_REG(1),
                .DOB_REG(1),
                .EN_ECC_READ("FALSE"),
                .EN_ECC_WRITE("FALSE"),
                .WRITE_MODE_A("READ_FIRST"),
                .WRITE_MODE_B("READ_FIRST"),
                .RDADDR_COLLISION_HWCONFIG("DELAYED_WRITE"),
                .SIM_COLLISION_CHECK("ALL"),
                .SIM_DEVICE("7SERIES")
            ) u_memory (
                .CLKARDCLK(clk),
                .CLKBWRCLK(clk),
                .ADDRARDADDR({1'b1,1'b0,read_address,6'b111111}),
                .ADDRBWRADDR({1'b1,1'b0,write_address,6'b111111}),
                .ENARDEN(read_fire && (!ENABLE_READ_BANK_MASK || rd_bank_mask[b])),
                .ENBWREN(bank_write_fire),
                .WEBWE(bank_byte_we),
                .WEA(4'b0),
                .DIADI(wr_data[31:0]),
                .DIBDI(wr_data[63:32]),
                .DIPADIP(4'b0),
                .DIPBDIP(4'b0),
                .DOADO(rsp_data[b*DATA_W+:32]),
                .DOBDO(rsp_data[b*DATA_W+32+:32]),
                .DOPADOP(),
                .DOPBDOP(),
                .REGCEAREGCE(output_advance),
                .REGCEB(1'b0),
                .RSTRAMARSTRAM(1'b0),
                .RSTRAMB(1'b0),
                .RSTREGARSTREG(1'b0),
                .RSTREGB(1'b0),
                .CASCADEINA(1'b0),
                .CASCADEINB(1'b0),
                .CASCADEOUTA(),
                .CASCADEOUTB(),
                .INJECTSBITERR(1'b0),
                .INJECTDBITERR(1'b0),
                .DBITERR(),
                .SBITERR(),
                .ECCPARITY(),
                .RDADDRECC()
            );
        end else begin : g_xpm
        // Generic configurations retain XPM. Byte strobes are essential:
        // the loader fills a word over multiple channel writes. enb admits
        // a latch payload; regceb independently advances the output stage.
        xpm_memory_sdpram #(
            .ADDR_WIDTH_A(ROW_W+1),
            .ADDR_WIDTH_B(ROW_W+1),
            .AUTO_SLEEP_TIME(0),
            .BYTE_WRITE_WIDTH_A(8),
            .CASCADE_HEIGHT(0),
            .CLOCKING_MODE("common_clock"),
            .ECC_MODE("no_ecc"),
            .MEMORY_INIT_FILE("none"),
            .MEMORY_INIT_PARAM("0"),
            .MEMORY_OPTIMIZATION("true"),
            .MEMORY_PRIMITIVE("block"),
            .MEMORY_SIZE(BANK_BITS),
            .MESSAGE_CONTROL(1),
            .READ_DATA_WIDTH_B(DATA_W),
            .READ_LATENCY_B(READ_LATENCY),
            .READ_RESET_VALUE_B("0"),
            .RST_MODE_A("SYNC"),
            .RST_MODE_B("SYNC"),
            .SIM_ASSERT_CHK(1),
            .USE_EMBEDDED_CONSTRAINT(0),
            .USE_MEM_INIT(0),
            .USE_MEM_INIT_MMI(0),
            .WAKEUP_TIME("disable_sleep"),
            .WRITE_DATA_WIDTH_A(DATA_W),
            .WRITE_MODE_B("no_change"),
            // bank_byte_we is zero whenever ena is zero, so XPM's optional
            // second write-protection gate is unnecessary and can be omitted.
            .WRITE_PROTECT(0)
        ) u_memory (
            .clka(clk),
            .ena(bank_write_fire),
            .wea(bank_byte_we),
            .addra(write_address),
            .dina(wr_data),
            .injectsbiterra(1'b0),
            .injectdbiterra(1'b0),
            .clkb(clk),
            .rstb(1'b0),
            .enb(read_fire && (!ENABLE_READ_BANK_MASK || rd_bank_mask[b])),
            .regceb(READ_LATENCY==1 ? 1'b1 : output_advance),
            .addrb(read_address),
            .doutb(rsp_data[b*DATA_W+:DATA_W]),
            .sbiterrb(),
            .dbiterrb(),
            .sleep(1'b0)
        );
        end
    end endgenerate
endmodule

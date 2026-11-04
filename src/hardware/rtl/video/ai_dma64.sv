`timescale 1ns/1ps
// Snapshot writer: one outstanding 16 x 64-bit INCR transaction. All clients
// provide 128-byte-aligned addresses, so a burst cannot cross a 4 KiB boundary.
// Soft abort is handled by clients: a launched transaction MUST drain normally.
module ai_dma64 (
    input wire clk, resetn,
    input wire wr_req, output wire wr_accept, input wire [31:0] wr_addr,
    input wire [63:0] wr_data, input wire wr_valid, output wire wr_ready,
    output reg wr_done, wr_error,
    output reg [31:0] m_axi_awaddr, output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize, output wire [1:0] m_axi_awburst,
    output wire m_axi_awlock, output wire [3:0] m_axi_awcache,
    output wire [2:0] m_axi_awprot, output reg m_axi_awvalid, input wire m_axi_awready,
    output wire [63:0] m_axi_wdata, output wire [7:0] m_axi_wstrb,
    output wire m_axi_wlast, m_axi_wvalid, input wire m_axi_wready,
    input wire [1:0] m_axi_bresp, input wire m_axi_bvalid, output wire m_axi_bready,
    output wire [31:0] m_axi_araddr, output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize, output wire [1:0] m_axi_arburst,
    output wire m_axi_arlock, output wire [3:0] m_axi_arcache,
    output wire [2:0] m_axi_arprot, output wire m_axi_arvalid, input wire m_axi_arready,
    input wire [63:0] m_axi_rdata, input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast, m_axi_rvalid, output wire m_axi_rready
);
    reg wb, wfinished;
    reg [3:0] wn;
    assign m_axi_awlen=15; assign m_axi_arlen=15;
    assign m_axi_awsize=3; assign m_axi_arsize=3;
    assign m_axi_awburst=1; assign m_axi_arburst=1;
    assign m_axi_awlock=0; assign m_axi_arlock=0;
    assign m_axi_awcache=4'b0011; assign m_axi_arcache=4'b0011;
    assign m_axi_awprot=0; assign m_axi_arprot=0;
    assign wr_accept=wr_req && !wb;
    assign wr_ready=wb && !wfinished && m_axi_wready;
    assign m_axi_wvalid=wb && !wfinished && wr_valid;
    assign m_axi_wdata=wr_data; assign m_axi_wstrb=8'hff;
    assign m_axi_wlast=(wn==15);
    assign m_axi_bready=wb && wfinished && !m_axi_awvalid;
    // Preserve the BD-facing AXI shape; this frontend never issues reads.
    assign m_axi_araddr=0; assign m_axi_arvalid=0; assign m_axi_rready=0;
    always @(posedge clk) begin
        if (!resetn) begin
            wb<=0; wn<=0; wfinished<=0;
            m_axi_awvalid<=0; m_axi_awaddr<=0;
            wr_done<=0; wr_error<=0;
        end else begin
            wr_done<=0;
            if (wr_accept) begin
                wb<=1; wn<=0; wfinished<=0; wr_error<=0;
                m_axi_awaddr<=wr_addr; m_axi_awvalid<=1;
            end
            if (m_axi_awvalid && m_axi_awready) m_axi_awvalid<=0;
            if (m_axi_wvalid && m_axi_wready) begin
                wn<=wn+1'b1;
                if (wn==15) wfinished<=1;
            end
            if (m_axi_bvalid && m_axi_bready) begin
                wb<=0; wr_done<=1; wr_error<=m_axi_bresp!=0;
            end

        end
    end
endmodule

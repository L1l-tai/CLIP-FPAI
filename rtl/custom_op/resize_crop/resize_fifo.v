//================================================================================
// File Name     : resize_fifo.v
// Project       :
// Create Date   : 2026.05.21
// Description   : Pixel accumulation FIFO for resize output
//                 批量写入 + 16 像素读出，读写合并为单一 always 块
//================================================================================

module resize_fifo #(
    parameter FIFO_DEPTH = 32,
    parameter PIXEL_W    = 32
) (
    input                       clk,
    input                       rst_n,

    input                       batch_wr_en,
    input       [511:0]         batch_wr_data,
    input       [4:0]           batch_wr_count,

    input                       rd_en,
    input                       force_rd,
    output reg  [511:0]         rd_data,
    output reg                  rd_valid,

    output      [5:0]           fifo_cnt,
    output                      flush_ready,
    output                      fifo_empty,
    output                      fifo_full
);

    reg [PIXEL_W-1:0] pixel_mem [0:FIFO_DEPTH-1];
    reg [4:0]  wr_ptr;
    reg [4:0]  rd_ptr;
    reg [5:0]  pixel_count;

    assign fifo_cnt    = pixel_count;
    assign flush_ready = (pixel_count >= 6'd16);
    assign fifo_empty  = (pixel_count == 6'd0);
    assign fifo_full   = (pixel_count == FIFO_DEPTH);

    // 从 512-bit 拆出 16 个像素
    wire [31:0] batch_pixel [15:0];
    genvar bp;
    generate
        for (bp = 0; bp < 16; bp = bp + 1) begin : bp_gen
            assign batch_pixel[bp] = batch_wr_data[bp*32 +: 32];
        end
    endgenerate

    // 读地址计算: DEPTH=32, 5-bit 自然截断 = 模 32
    function [4:0] rd_addr;
        input [4:0] base;
        input [4:0] offset;
        begin
            rd_addr = {1'b0, base} + {1'b0, offset};
        end
    endfunction

    // 组合逻辑读出
    wire [511:0] rd_data_comb;
    assign rd_data_comb = {
        pixel_mem[rd_addr(rd_ptr, 5'd15)],
        pixel_mem[rd_addr(rd_ptr, 5'd14)],
        pixel_mem[rd_addr(rd_ptr, 5'd13)],
        pixel_mem[rd_addr(rd_ptr, 5'd12)],
        pixel_mem[rd_addr(rd_ptr, 5'd11)],
        pixel_mem[rd_addr(rd_ptr, 5'd10)],
        pixel_mem[rd_addr(rd_ptr, 5'd9)],
        pixel_mem[rd_addr(rd_ptr, 5'd8)],
        pixel_mem[rd_addr(rd_ptr, 5'd7)],
        pixel_mem[rd_addr(rd_ptr, 5'd6)],
        pixel_mem[rd_addr(rd_ptr, 5'd5)],
        pixel_mem[rd_addr(rd_ptr, 5'd4)],
        pixel_mem[rd_addr(rd_ptr, 5'd3)],
        pixel_mem[rd_addr(rd_ptr, 5'd2)],
        pixel_mem[rd_addr(rd_ptr, 5'd1)],
        pixel_mem[rd_addr(rd_ptr, 5'd0)]
    };

    // ============ 单一 always 块: 写 + 读 (避免 pixel_count 多驱动) ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= #0.1 5'd0;
            rd_ptr      <= #0.1 5'd0;
            rd_data     <= #0.1 512'd0;
            rd_valid    <= #0.1 1'b0;
            pixel_count <= #0.1 6'd0;
        end
        else begin
            // 批量写
            if (batch_wr_en && (pixel_count + batch_wr_count <= FIFO_DEPTH[5:0])) begin
                if (batch_wr_count > 5'd0)  pixel_mem[wr_ptr + 5'd0]  <= #0.1 batch_pixel[ 0];
                if (batch_wr_count > 5'd1)  pixel_mem[wr_ptr + 5'd1]  <= #0.1 batch_pixel[ 1];
                if (batch_wr_count > 5'd2)  pixel_mem[wr_ptr + 5'd2]  <= #0.1 batch_pixel[ 2];
                if (batch_wr_count > 5'd3)  pixel_mem[wr_ptr + 5'd3]  <= #0.1 batch_pixel[ 3];
                if (batch_wr_count > 5'd4)  pixel_mem[wr_ptr + 5'd4]  <= #0.1 batch_pixel[ 4];
                if (batch_wr_count > 5'd5)  pixel_mem[wr_ptr + 5'd5]  <= #0.1 batch_pixel[ 5];
                if (batch_wr_count > 5'd6)  pixel_mem[wr_ptr + 5'd6]  <= #0.1 batch_pixel[ 6];
                if (batch_wr_count > 5'd7)  pixel_mem[wr_ptr + 5'd7]  <= #0.1 batch_pixel[ 7];
                if (batch_wr_count > 5'd8)  pixel_mem[wr_ptr + 5'd8]  <= #0.1 batch_pixel[ 8];
                if (batch_wr_count > 5'd9)  pixel_mem[wr_ptr + 5'd9]  <= #0.1 batch_pixel[ 9];
                if (batch_wr_count > 5'd10) pixel_mem[wr_ptr + 5'd10] <= #0.1 batch_pixel[10];
                if (batch_wr_count > 5'd11) pixel_mem[wr_ptr + 5'd11] <= #0.1 batch_pixel[11];
                if (batch_wr_count > 5'd12) pixel_mem[wr_ptr + 5'd12] <= #0.1 batch_pixel[12];
                if (batch_wr_count > 5'd13) pixel_mem[wr_ptr + 5'd13] <= #0.1 batch_pixel[13];
                if (batch_wr_count > 5'd14) pixel_mem[wr_ptr + 5'd14] <= #0.1 batch_pixel[14];
                if (batch_wr_count > 5'd15) pixel_mem[wr_ptr + 5'd15] <= #0.1 batch_pixel[15];
                wr_ptr      <= #0.1 wr_ptr + batch_wr_count;
                pixel_count <= #0.1 pixel_count + batch_wr_count;
            end
            // 正常读
            else if (rd_en && flush_ready) begin
                rd_data     <= #0.1 rd_data_comb;
                rd_valid    <= #0.1 1'b1;
                rd_ptr      <= #0.1 rd_ptr + 5'd16;
                pixel_count <= #0.1 pixel_count - 6'd16;
            end
            // 强制排空
            else if (force_rd && !fifo_empty) begin
                rd_data     <= #0.1 rd_data_comb;
                rd_valid    <= #0.1 1'b1;
                rd_ptr      <= #0.1 5'd0;
                pixel_count <= #0.1 6'd0;
            end
            else begin
                rd_valid <= #0.1 1'b0;
            end
        end
    end

endmodule

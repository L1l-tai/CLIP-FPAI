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

    wire [31:0] batch_pixel [15:0];
    wire [511:0] slot_a;
    wire [511:0] slot_b;
    wire [511:0] rd_data_comb;

    // 从 512-bit 拆出 16 个像素
    genvar bp;
    generate
        for (bp = 0; bp < 16; bp = bp + 1) begin : bp_gen
            assign batch_pixel[bp] = batch_wr_data[bp*32 +: 32];
        end
    endgenerate

    // 组合逻辑读出: rd_ptr 仅 0/16 两种状态, 2:1 MUX 替代 16 路加法
    assign slot_a = {pixel_mem[15], pixel_mem[14], pixel_mem[13], pixel_mem[12],
                     pixel_mem[11], pixel_mem[10], pixel_mem[ 9], pixel_mem[ 8],
                     pixel_mem[ 7], pixel_mem[ 6], pixel_mem[ 5], pixel_mem[ 4],
                     pixel_mem[ 3], pixel_mem[ 2], pixel_mem[ 1], pixel_mem[ 0]};
    assign slot_b = {pixel_mem[31], pixel_mem[30], pixel_mem[29], pixel_mem[28],
                     pixel_mem[27], pixel_mem[26], pixel_mem[25], pixel_mem[24],
                     pixel_mem[23], pixel_mem[22], pixel_mem[21], pixel_mem[20],
                     pixel_mem[19], pixel_mem[18], pixel_mem[17], pixel_mem[16]};
    assign rd_data_comb = (rd_ptr == 5'd0) ? slot_a : slot_b;

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
            // 批量写: 无条件写入全部 16 像素, 无效数据由下一块覆盖
            if (batch_wr_en && !fifo_full) begin
                pixel_mem[wr_ptr + 5'd0]  <= #0.1 batch_pixel[ 0];
                pixel_mem[wr_ptr + 5'd1]  <= #0.1 batch_pixel[ 1];
                pixel_mem[wr_ptr + 5'd2]  <= #0.1 batch_pixel[ 2];
                pixel_mem[wr_ptr + 5'd3]  <= #0.1 batch_pixel[ 3];
                pixel_mem[wr_ptr + 5'd4]  <= #0.1 batch_pixel[ 4];
                pixel_mem[wr_ptr + 5'd5]  <= #0.1 batch_pixel[ 5];
                pixel_mem[wr_ptr + 5'd6]  <= #0.1 batch_pixel[ 6];
                pixel_mem[wr_ptr + 5'd7]  <= #0.1 batch_pixel[ 7];
                pixel_mem[wr_ptr + 5'd8]  <= #0.1 batch_pixel[ 8];
                pixel_mem[wr_ptr + 5'd9]  <= #0.1 batch_pixel[ 9];
                pixel_mem[wr_ptr + 5'd10] <= #0.1 batch_pixel[10];
                pixel_mem[wr_ptr + 5'd11] <= #0.1 batch_pixel[11];
                pixel_mem[wr_ptr + 5'd12] <= #0.1 batch_pixel[12];
                pixel_mem[wr_ptr + 5'd13] <= #0.1 batch_pixel[13];
                pixel_mem[wr_ptr + 5'd14] <= #0.1 batch_pixel[14];
                pixel_mem[wr_ptr + 5'd15] <= #0.1 batch_pixel[15];
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

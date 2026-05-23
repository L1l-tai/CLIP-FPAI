//================================================================================
// File Name     : resize_addr_gen.v
// Project       :
// Create Date   : 2026.04.27
// Description   : Resize address generation module
//================================================================================

module resize_addr_gen(
    input        [1:0]      trans_status  ,
    input                   rd_second     ,
    input                   gen_status    ,

    input        [15 : 0]   crop_off_x   ,
    input        [15 : 0]   crop_off_y   ,
    input        [15 : 0]   crop_size    ,

    input        [31 : 0]   rbase_rs     ,
    input        [15 : 0]   rwidth_rs     ,
    input        [15 : 0]   wheight_rs   ,
    input        [15 : 0]   dst_width    ,
    input        [31 : 0]   wbase_rs     ,

    input        [15:0]     y_bias        ,

    output  reg             rs_addr_gen_valid ,
    output  reg  [31 : 0]   arbase_rs_gen,
    output  reg  [31 : 0]   arbase_rs_gen_2,
    output  reg  [15 : 0]   arsize_rs_gen,
    output  reg  [31 : 0]   awbase_rs_gen,
    output  reg  [15 : 0]   awsize_rs_gen,
    output  wire [31 : 0]   awbase_comb,     // 组合逻辑写地址, 始终反映当前 rs_wr_cnt
    output  reg             rs_first_line,
    output  reg             rs_last_line,
    output  wire            src_done     ,

    input                   comp_done_rs ,

    input                   clk          ,
    input                   rst_n
);

    localparam RS_WIDTH = 1;
    localparam RS_SHIFT = 6;   // 64 bytes per block

    // ============ 寄存器声明 ============
    reg [15:0] rs_rd_cnt;
    reg [15:0] rs_wr_cnt;
    reg [15:0] total_rd_cnt;
    reg [15:0] y_bias_prev;
    reg [ 1:0] trans_status_reg;
    reg [31:0] rbase_rs_reg;
    reg [31:0] wbase_rs_reg;
    reg        pipe_valid;

    // ============ 连线声明 ============
    wire       rd_pos;
    wire       wr_pos;
    wire       row_changed;
    wire [15:0] addr_rd_cnt;
    wire [15:0] rs_num;
    wire [31:0] arbase_offset_c;
    wire [31:0] y_bias_x_rwidth;
    wire [31:0] y_bias_p1_x_rwidth;
    wire [31:0] arbase_rs_gen_c;
    wire [31:0] arbase_rs_gen_2_c;
    wire [31:0] awbase_rs_gen_c;

    // ============ 边沿检测 ============
    assign rd_pos = ~trans_status_reg[0] & trans_status[0];
    assign wr_pos = ~trans_status_reg[1] & trans_status[1];

    // ============ 行切换检测 ============
    assign row_changed = (y_bias != y_bias_prev);

    // ============ 常数计算 ============
    wire [15:0] dst_blocks_per_row  = (dst_width + 15) >> 4;
    wire [15:0] src_blocks_per_row  = (crop_size + 15) >> 4;
    wire [15:0] total_src_blocks    = wheight_rs * src_blocks_per_row;

    assign rs_num    = wheight_rs * dst_blocks_per_row;
    assign src_done  = (total_rd_cnt >= total_src_blocks);

    // ============ 地址计算 (组合逻辑) ============
    assign y_bias_x_rwidth    = (y_bias + crop_off_y) * (rwidth_rs << 2);
    assign y_bias_p1_x_rwidth = (y_bias + crop_off_y + 16'd1) * (rwidth_rs << 2);

    assign addr_rd_cnt      = (gen_status && row_changed) ? 16'd0 : rs_rd_cnt;
    assign arbase_offset_c  = crop_off_x * 4 + (addr_rd_cnt << RS_SHIFT);

    assign arbase_rs_gen_c  = rbase_rs_reg + y_bias_x_rwidth + arbase_offset_c;
    assign arbase_rs_gen_2_c = rbase_rs_reg + y_bias_p1_x_rwidth + arbase_offset_c;
    assign awbase_rs_gen_c  = wbase_rs_reg + (rs_wr_cnt << RS_SHIFT);
    assign awbase_comb      = awbase_rs_gen_c;

    // ============ trans_status 延迟 ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            trans_status_reg <= #0.1 2'b00;
        else
            trans_status_reg <= #0.1 trans_status;
    end

    // ============ rs_rd_cnt / total_rd_cnt / y_bias_prev ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs_rd_cnt    <= #0.1 16'd0;
            total_rd_cnt <= #0.1 16'd0;
            y_bias_prev  <= #0.1 16'd0;
        end
        else begin
            if (gen_status) begin
                y_bias_prev <= #0.1 y_bias;
                if (row_changed)
                    rs_rd_cnt <= #0.1 16'd0;
            end
            if (rd_pos & ~rd_second) begin
                rs_rd_cnt    <= #0.1 rs_rd_cnt + 16'd1;
                total_rd_cnt <= #0.1 total_rd_cnt + 16'd1;
            end
            if (comp_done_rs) begin
                rs_rd_cnt    <= #0.1 16'd0;
                total_rd_cnt <= #0.1 16'd0;
                y_bias_prev  <= #0.1 16'd0;
            end
        end
    end

    // ============ rs_wr_cnt ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rs_wr_cnt <= #0.1 16'd0;
        else if (wr_pos)
            rs_wr_cnt <= #0.1 rs_wr_cnt + 16'd1;
        else if (comp_done_rs)
            rs_wr_cnt <= #0.1 16'd0;
    end

    // ============ 第一级流水线 (gen_status → latch) ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rbase_rs_reg <= #0.1 32'd0;
            wbase_rs_reg <= #0.1 32'd0;
            pipe_valid   <= #0.1 1'b0;
        end
        else if (gen_status) begin
            rbase_rs_reg <= #0.1 rbase_rs;
            wbase_rs_reg <= #0.1 wbase_rs;
            pipe_valid   <= #0.1 1'b1;
        end
        else begin
            pipe_valid <= #0.1 1'b0;
        end
    end

    // ============ 第二级流水线 (pipe_valid → output) ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs_addr_gen_valid <= #0.1 1'b0;
            arbase_rs_gen     <= #0.1 32'd0;
            arbase_rs_gen_2   <= #0.1 32'd0;
            arsize_rs_gen     <= #0.1 16'd0;
            awbase_rs_gen     <= #0.1 32'd0;
            awsize_rs_gen     <= #0.1 16'd0;
        end
        else if (pipe_valid) begin
            rs_addr_gen_valid <= #0.1 1'b1;
            arbase_rs_gen     <= #0.1 arbase_rs_gen_c;
            arbase_rs_gen_2   <= #0.1 arbase_rs_gen_2_c;
            arsize_rs_gen     <= #0.1 RS_WIDTH;
            awbase_rs_gen     <= #0.1 awbase_rs_gen_c;
            awsize_rs_gen     <= #0.1 RS_WIDTH;
        end
        else begin
            rs_addr_gen_valid <= #0.1 1'b0;
        end
    end

    // ============ rs_first_line / rs_last_line ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs_first_line <= #0.1 1'b0;
            rs_last_line  <= #0.1 1'b0;
        end
        else if (gen_status) begin
            rs_first_line <= #0.1 (total_rd_cnt == 16'd0);
            rs_last_line  <= #0.1 (rs_wr_cnt == rs_num - 1);
        end
        else if (comp_done_rs) begin
            rs_first_line <= #0.1 1'b0;
            rs_last_line  <= #0.1 1'b0;
        end
    end

endmodule

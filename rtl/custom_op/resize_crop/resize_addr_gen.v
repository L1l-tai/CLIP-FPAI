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
    reg        pipe_valid_2;
    reg [16:0] y_bias_sum_r;
    reg [16:0] y_bias_sum_p1_r;
    reg [31:0] y_bias_x_rwidth_r;
    reg [31:0] y_bias_p1_x_rwidth_r;
    reg [15:0] total_src_blocks_r;
    reg [15:0] rs_num_r;

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
    assign src_done  = (total_rd_cnt >= total_src_blocks_r);

    // 寄存常量乘积, 消除 DSP→比较器 的长组合路径
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_src_blocks_r <= #0.1 16'd0;
            rs_num_r           <= #0.1 16'd0;
        end
        else begin
            total_src_blocks_r <= #0.1 total_src_blocks;
            rs_num_r           <= #0.1 rs_num;
        end
    end

    // ============ 地址计算 (组合逻辑) ============
    // 用位拼接替代 << 和 * 常数, 避免综合工具误推 DSP
    wire [17:0] rwidth_bytes  = {rwidth_rs,  2'b0};  // rwidth_rs * 4
    wire [17:0] crop_off_x_b  = {crop_off_x, 2'b0};  // crop_off_x * 4

    // 加法独立 (Stage2 锁存) — 路径: reg→adder→reg
    wire [16:0] y_bias_sum    = y_bias + crop_off_y;
    wire [16:0] y_bias_sum_p1 = y_bias + crop_off_y + 16'd1;

    // DSP 乘法 (Stage3 锁存) — 路径: reg(加法结果)→DSP→reg
    assign y_bias_x_rwidth    = y_bias_sum_r * rwidth_bytes;
    assign y_bias_p1_x_rwidth = y_bias_sum_p1_r * rwidth_bytes;

    assign addr_rd_cnt      = (gen_status && row_changed) ? 16'd0 : rs_rd_cnt;
    assign arbase_offset_c  = crop_off_x_b + (addr_rd_cnt << RS_SHIFT);

    // 地址累加 (Stage4 锁存) — 路径: reg+reg+comb→reg
    assign arbase_rs_gen_c   = rbase_rs_reg + y_bias_x_rwidth_r + arbase_offset_c;
    assign arbase_rs_gen_2_c = rbase_rs_reg + y_bias_p1_x_rwidth_r + arbase_offset_c;
    assign awbase_rs_gen_c   = wbase_rs_reg + (rs_wr_cnt << RS_SHIFT);
    assign awbase_comb       = awbase_rs_gen_c;

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

    // ============ 第一级流水线 (gen_status → rbase/wbase + y_bias加法) ============
    // y_bias 已在 AXIS_CAL 内提前更新, 此时稳定
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rbase_rs_reg <= #0.1 32'd0;
            wbase_rs_reg <= #0.1 32'd0;
            y_bias_sum_r    <= #0.1 17'd0;
            y_bias_sum_p1_r <= #0.1 17'd0;
            pipe_valid   <= #0.1 1'b0;
        end
        else if (gen_status) begin
            rbase_rs_reg <= #0.1 rbase_rs;
            wbase_rs_reg <= #0.1 wbase_rs;
            y_bias_sum_r    <= #0.1 y_bias_sum;
            y_bias_sum_p1_r <= #0.1 y_bias_sum_p1;
            pipe_valid   <= #0.1 1'b1;
        end
        else begin
            pipe_valid <= #0.1 1'b0;
        end
    end

    // ============ 第二级流水线 (pipe_valid → latch DSP 乘积) ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_bias_x_rwidth_r    <= #0.1 32'd0;
            y_bias_p1_x_rwidth_r <= #0.1 32'd0;
            pipe_valid_2         <= #0.1 1'b0;
        end
        else begin
            pipe_valid_2 <= #0.1 pipe_valid;
            if (pipe_valid) begin
                y_bias_x_rwidth_r    <= #0.1 y_bias_x_rwidth;
                y_bias_p1_x_rwidth_r <= #0.1 y_bias_p1_x_rwidth;
            end
        end
    end

    // ============ 第三级流水线 (pipe_valid_2 → output) ============
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs_addr_gen_valid <= #0.1 1'b0;
            arbase_rs_gen     <= #0.1 32'd0;
            arbase_rs_gen_2   <= #0.1 32'd0;
            arsize_rs_gen     <= #0.1 16'd0;
            awbase_rs_gen     <= #0.1 32'd0;
            awsize_rs_gen     <= #0.1 16'd0;
        end
        else if (pipe_valid_2) begin
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
            rs_last_line  <= #0.1 (rs_wr_cnt == rs_num_r - 1);
        end
        else if (comp_done_rs) begin
            rs_first_line <= #0.1 1'b0;
            rs_last_line  <= #0.1 1'b0;
        end
    end

endmodule

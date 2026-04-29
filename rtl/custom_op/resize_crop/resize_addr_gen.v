//================================================================================
// Orgnization   : School of Electronic Science, NUDT
// File Name     : resize_addr_gen.v
// Author        : Changtai Lin
// Project       :
// Create Date   : 2026.04.27
// Description   : Resize address generation module
//
//--------------------------------------------------------------------------------
// Modification History :
//================================================================================

module resize_addr_gen(
    input        [1:0]      trans_status  ,
    input                   rd_second     ,
    input                   gen_status    ,

    input        [31 : 0]   rbase_rs     ,
    input        [15 : 0]   rwidth_rs     ,
    input        [15 : 0]   rheight_rs    ,
    //需要读写的总数据包数(512bit)
    input        [15 : 0]   wwidth_rs    ,
    input        [15 : 0]   wheight_rs   ,
    input        [31 : 0]   wbase_rs     ,

    // 来自 resize_axis 的坐标映射信号
    input        [8:0]     data_valid,        // 16个数据中的有效个数
    input        [7:0]     y_delta,          // P点相对于下一行的y偏移
    input        [15:0]    y_bias,           // y轴偏移量对应的行

    output  reg             rs_addr_gen_valid ,
    output  reg  [31 : 0]   arbase_rs_gen,
    output  reg  [31 : 0]   arbase_rs_gen_2,
    output  reg  [15 : 0]   arsize_rs_gen,
    output  reg  [31 : 0]   awbase_rs_gen,
    output  reg  [15 : 0]   awsize_rs_gen,
    output  reg             rs_first_line,
    output  reg             rs_last_line,

    input                   comp_done_rs     ,

    input                   clk           ,
    input                   rst_n
);

localparam RS_WIDTH = 1;   // only 1 beats per row
localparam RS_SHIFT = 4;   // 每次迭代地址偏移16字节 (512/32 2^4)

reg     [15 : 0]            rs_rd_cnt;
reg     [15 : 0]            rs_wr_cnt;
reg     [1 : 0]             trans_status_reg;


wire       [31 : 0]         arbase_rs_gen_c;
wire       [31 : 0]         arbase_rs_gen_2_c;
wire       [15 : 0]         arsize_rs_gen_c;
wire       [31 : 0]         awbase_rs_gen_c;
wire       [15 : 0]         awsize_rs_gen_c;
wire       [31 : 0]         arbase_offset_c;
wire       [31 : 0]         awbase_offset_c;

wire       [15 : 0]         rs_num;
wire                        rd_pos;
wire                        wr_pos;

// 第一级流水线: 乘法结果
wire    [31:0]             y_bias_x_rwidth;     // y_bias * rwidth_rs * 4
wire    [31:0]             y_bias_p1_x_rwidth;   // (y_bias + 1) * rwidth_rs * 4

// 第一级流水线寄存器
reg     [31:0]             rbase_rs_reg;
reg     [31:0]            wbase_rs_reg;
reg     [31:0]             arbase_offset_r;
reg     [31:0]             y_bias_x_rwidth_r;
reg     [31:0]             y_bias_p1_x_rwidth_r;
reg                         pipe_valid;            // 第一级流水线有效信号(延迟gen_status一个周期)

// 第二级流水线结果
wire    [31:0]             arbase_rs_gen_c_full;
wire    [31:0]             arbase_rs_gen_2_c_full;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        trans_status_reg <= #0.1 2'b00;
    end
    else begin
        trans_status_reg <= #0.1 trans_status;
    end
end


always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rs_rd_cnt <= #0.1 16'd0;
    end
    else begin
        if(rd_pos & ~rd_second) begin
            //每完成一次地址生成，即进入下一个状态时，cnt加1
            rs_rd_cnt <= #0.1 rs_rd_cnt + 16'd1;
        end
        else if(comp_done_rs) begin
            rs_rd_cnt <= #0.1 16'd0;
        end
        else begin
            rs_rd_cnt <= #0.1 rs_rd_cnt;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rs_wr_cnt <= #0.1 16'd0;
    end
    else begin
        if(wr_pos) begin
            //每完成一次地址生成，即进入下一个状态时，cnt加1
            rs_wr_cnt <= #0.1 rs_wr_cnt + 16'd1;
        end
        else if(comp_done_rs) begin
            rs_wr_cnt <= #0.1 16'd0;
        end
        else begin
            rs_wr_cnt <= #0.1 rs_wr_cnt;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rs_addr_gen_valid <= #0.1 1'b0;
        arbase_rs_gen <= #0.1 32'b0;
        arbase_rs_gen_2 <= #0.1 32'b0;
        arsize_rs_gen <= #0.1 16'b0;
        awbase_rs_gen <= #0.1 32'b0;
        awsize_rs_gen <= #0.1 16'b0;
    end
    else begin
        if(pipe_valid) begin
            // pipe_valid 为高时(第一级计算结果就绪)，输出第二级计算结果
            rs_addr_gen_valid <= #0.1 1'b1;
            arbase_rs_gen <= #0.1 arbase_rs_gen_c;
            arbase_rs_gen_2 <= #0.1 arbase_rs_gen_2_c;
            arsize_rs_gen <= #0.1 arsize_rs_gen_c;
            awbase_rs_gen <= #0.1 awbase_rs_gen_c;
            awsize_rs_gen <= #0.1 awsize_rs_gen_c;
        end
        else begin
            rs_addr_gen_valid <= #0.1 1'b0;
            arbase_rs_gen <= arbase_rs_gen;
            arbase_rs_gen_2 <= arbase_rs_gen_2;
            arsize_rs_gen <= arsize_rs_gen;
            awbase_rs_gen <= awbase_rs_gen;
            awsize_rs_gen <= awsize_rs_gen;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rs_last_line <= #0.1 1'b0;
        rs_first_line <= #0.1 1'b0;
    end
    else begin
        if(gen_status) begin
            rs_last_line <= #0.1 (rs_wr_cnt == rs_num - 1);
            rs_first_line <= #0.1 (rs_rd_cnt == 16'd0);
        end
        else if(comp_done_rs) begin
            rs_last_line <= #0.1 1'b0;
            rs_first_line <= #0.1 1'b0;
        end
        else begin
            rs_last_line <= #0.1 rs_last_line;
            rs_first_line <= #0.1 rs_first_line;
        end
    end
end

assign rs_num = wheight_rs * (rwidth_rs >> RS_SHIFT);  // 总行数用于判断 last_line

assign rd_pos = ~trans_status_reg[0] & trans_status[0];
assign wr_pos = ~trans_status_reg[1] & trans_status[1];

// 第一级流水线: 乘法计算
assign y_bias_x_rwidth = y_bias * (rwidth_rs << 2);      // y_bias * rwidth_rs * 4
assign y_bias_p1_x_rwidth = (y_bias + 16'd1) * (rwidth_rs << 2);  // (y_bias+1) * rwidth_rs * 4

// 第二级流水线: 加法计算
assign arbase_rs_gen_c_full = rbase_rs_reg + y_bias_x_rwidth_r + arbase_offset_r;
assign arbase_rs_gen_2_c_full = rbase_rs_reg + y_bias_p1_x_rwidth_r + arbase_offset_r;

// 第一级流水线寄存器: 锁存乘法结果和有效信号
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wbase_rs_reg <= #0.1 32'd0;
        rbase_rs_reg <= #0.1 32'd0;
        arbase_offset_r <= #0.1 32'd0;
        y_bias_x_rwidth_r <= #0.1 32'd0;
        y_bias_p1_x_rwidth_r <= #0.1 32'd0;
        pipe_valid <= #0.1 1'b0;
    end
    else if (gen_status) begin
        wbase_rs_reg <= #0.1 wbase_rs;
        rbase_rs_reg <= #0.1 rbase_rs;
        arbase_offset_r <= #0.1 arbase_offset_c;
        y_bias_x_rwidth_r <= #0.1 y_bias_x_rwidth;
        y_bias_p1_x_rwidth_r <= #0.1 y_bias_p1_x_rwidth;
        pipe_valid <= #0.1 gen_status;  // gen_status 延迟一个周期作为第一级有效信号
    end
    else begin
        rbase_rs_reg <= #0.1 rbase_rs_reg;
        wbase_rs_reg <= #0.1 wbase_rs_reg;
        arbase_offset_r <= #0.1 arbase_offset_r;
        y_bias_x_rwidth_r <= #0.1 y_bias_x_rwidth_r;
        y_bias_p1_x_rwidth_r <= #0.1 y_bias_p1_x_rwidth_r;
        pipe_valid <= #0.1 pipe_valid;
    end
end

assign arbase_offset_c = rs_rd_cnt << RS_SHIFT ;  // 16 bytes per beat
assign arbase_rs_gen_c = arbase_rs_gen_c_full;
// 第二行基地址 = 第一行基地址 + 一行字节数 (rwidth_rs * 4 bytes)
assign arbase_rs_gen_2_c = arbase_rs_gen_2_c_full;
assign arsize_rs_gen_c = RS_WIDTH;

assign awbase_offset_c = rs_wr_cnt << RS_SHIFT;
assign awbase_rs_gen_c = wbase_rs_reg + awbase_offset_c;
assign awsize_rs_gen_c = RS_WIDTH;

endmodule

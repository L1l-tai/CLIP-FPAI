//================================================================================
// File Name     : resize.v
// Project       : 
// Create Date   : 2026.04.20
// Description   :
// 
//--------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who               Description
// 0.5.0   2026.04.28              resize logic
//================================================================================

module resize (
    input                   gen_status    ,
    input                   resize_status ,
    input                   rd_second     ,
    input        [1 : 0]    trans_status  ,
    input                   wr_done       ,
    input                   axis_cal_done ,

    // 来自 resize_axis 的坐标映射信号
    input        [7:0]      data_valid    ,     // 16个数据中的有效个数
    input        [255:0]    x_delta       ,     // P点相对于起始原像素的x偏移
    input        [7:0]      y_delta       ,     // P点相对于下一行的y偏移

    input        [511 : 0]  din           ,
    input                   din_valid     ,
    output                  din_ready     ,

    output       [511 : 0]  dout          ,
    output                  dout_valid    ,
    input                   dout_ready    ,
    
    input                   comp_done     ,

    output                  resize_done   ,

    // FIFO 状态输出 → FSM
    output                  fifo_flush_ready,
    output                  fifo_empty,
    // FIFO drain 命令 ← FSM
    input                   fifo_drain,

    input                   clk           ,
    input                   rst_n
);

reg     [31 : 0]            rs_regs   [15:0];
reg     [31 : 0]            rs_regs_2 [15:0];
reg     [31 : 0]            rs_out_regs [15:0];
reg     [1 : 0]             trans_status_reg;
reg     [1 : 0]             rd_cnt;
reg     [1 : 0]             wr_cnt;

// 坐标计算寄存器
reg     [7:0]               data_valid_reg;
reg     [15:0]              x_delta_reg [15:0];  // 16个16bit元素
reg     [7:0]               y_delta_reg;
reg                         rd_second_reg;
wire                        rd_second_pos;

// resize_status 三级流水线寄存器
reg                         resize_status_r1;  // 第一级：坐标寄存器
reg                         resize_status_r2;  // 第二级：权重/像素值寄存器
reg                         resize_status_r3;  // 第三级：乘法结果/最终结果寄存器
reg                         resize_status_r4;
reg                         result_valid;
    reg                         result_valid_reg;
    wire                        result_valid_pos;


wire                        resize_status_r3_pos;

// ============ FIFO interface signals ============
// 批量写接口
wire                        batch_wr_en;
wire    [511:0]             batch_wr_data;
wire    [4:0]               batch_wr_count;
// 读接口
wire                        fifo_rd_en;
wire    [511:0]             fifo_rd_data;
wire                        fifo_rd_valid;
wire    [5:0]               fifo_cnt;
// fifo_flush_ready / fifo_empty 已作为 output port 声明
wire                        fifo_full;

wire    [511 : 0]           dout_rs    ;
wire                        dout_valid_rs  ;
wire                        dout_ready_rs  ;

// rd_second 上升沿检测
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_second_reg <= #0.1 1'b0;
    end
    else begin
        rd_second_reg <= #0.1 rd_second;
    end
end
assign rd_second_pos = rd_second & ~rd_second_reg;  // 上升沿检测

// 在rd_second上升沿时寄存坐标输入
genvar j;
generate
    for (j = 0; j < 16; j = j + 1) begin: x_delta_reg_gen
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                x_delta_reg[j] <= #0.1 16'd0;
            end
            else if (rd_second_pos) begin
                x_delta_reg[j] <= #0.1 x_delta[j * 16 +: 16];
            end
            else begin
                x_delta_reg[j] <= #0.1 x_delta_reg[j];
            end
        end
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        data_valid_reg <= #0.1 8'd0;
        y_delta_reg <= #0.1 8'd0;
    end
    else if (rd_second_pos) begin
        data_valid_reg <= #0.1 data_valid;
        y_delta_reg <= #0.1 y_delta;
    end
    else begin
        data_valid_reg <= #0.1 data_valid_reg;
        y_delta_reg <= #0.1 y_delta_reg;
    end
end

// resize_status 三级流水线寄存器更新
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        resize_status_r1 <= #0.1 1'b0;
        resize_status_r2 <= #0.1 1'b0;
        resize_status_r3 <= #0.1 1'b0;
        resize_status_r4 <= #0.1 1'b0;
    end
    else begin
        resize_status_r1 <= #0.1 resize_status;
        resize_status_r2 <= #0.1 resize_status_r1;
        resize_status_r3 <= #0.1 resize_status_r2;
        resize_status_r4 <= #0.1 resize_status_r3;
    end
end

// resize_status_r3 上升沿检测
assign resize_status_r3_pos = resize_status_r3 & ~resize_status_r4;

// resize_status 下降沿检测 (离开 RESIZE 状态时清零 result_valid)
reg  resize_status_reg;
wire resize_status_negedge = ~resize_status & resize_status_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        resize_status_reg <= #0.1 1'b0;
    else
        resize_status_reg <= #0.1 resize_status;
end

// result_valid: 在 resize_status_r3_pos 拉高, 离开 RESIZE 后清零
// result_valid_reg 在同一 always 块中更新, 保证与 result_valid 同步
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        result_valid     <= #0.1 1'b0;
        result_valid_reg <= #0.1 1'b0;
    end
    else begin
        result_valid_reg <= #0.1 result_valid;
        if (resize_status_r3_pos)
            result_valid <= #0.1 1'b1;
        else if (resize_status_negedge)
            result_valid <= #0.1 1'b0;
        else
            result_valid <= #0.1 result_valid;
    end
end
assign result_valid_pos = result_valid & ~result_valid_reg;

// ============ 批量写触发 ============
// result_valid_pos: 计算完成 (result_val 已稳定多周期)

// 批量写数据: 16 像素拼为 512-bit
assign batch_wr_data = {result_val[15], result_val[14], result_val[13], result_val[12],
                         result_val[11], result_val[10], result_val[ 9], result_val[ 8],
                         result_val[ 7], result_val[ 6], result_val[ 5], result_val[ 4],
                         result_val[ 3], result_val[ 2], result_val[ 1], result_val[ 0]};

assign batch_wr_en    = result_valid_pos;
assign batch_wr_count = data_valid_reg[4:0];

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
        rd_cnt <= #0.1 2'd0;
    end
    else begin
        if(din_valid & din_ready) begin
            rd_cnt <= #0.1 rd_cnt + 2'd1;
        end
        else if(comp_done | resize_status) begin
            //计算完成或读取完毕后，清零计数器
            rd_cnt <= #0.1 2'd0;
        end
        else begin
            rd_cnt <= #0.1 rd_cnt;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_cnt <= #0.1 2'd0;
    end
    else begin
        if(dout_valid & dout_ready) begin
            wr_cnt <= #0.1 wr_cnt + 2'd1;
        end
        else if(comp_done | resize_status) begin
            //算子处理完成或写入完毕后，清零计数器
            wr_cnt <= #0.1 2'd0;
        end
        else begin
            wr_cnt <= #0.1 wr_cnt;
        end
    end
end

// rd_second为低时赋值rs_regs，rd_second为高时赋值rs_regs_2
genvar i;
generate
    for (i = 0; i < 16; i = i + 1) begin: rs_regs_assign
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                rs_regs[i] <= #0.1 32'd0;
                rs_regs_2[i] <= #0.1 32'd0;
            end
            else if (din_valid & din_ready) begin
                if (~rd_second) begin
                    rs_regs[i] <= #0.1 din[i * 32 +: 32];
                end
                else begin
                    rs_regs_2[i] <= #0.1 din[i * 32 +: 32];
                end
            end
            else begin
                rs_regs[i] <= #0.1 rs_regs[i];
                rs_regs_2[i] <= #0.1 rs_regs_2[i];
            end
        end
    end
endgenerate

// ============================================================
// 双线性插值权重计算
// x_delta_reg[j]: 第j个像素点的x偏移 (低8位为无符号整数)
// y_delta_reg: P点y偏移 (低8位为无符号整数)
// 权重计算: w11 = (1-x)*(1-y), w12 = x*(1-y), w21 = (1-x)*y, w22 = x*y
// ============================================================

// y_delta_inv只取低8位作为无符号整型
wire    [3:0]               y_delta_inv;  // 1 - y_delta, 只取低8位
wire    [3:0]               y_delta_small;
// y_delta_inv = 256 - y_delta (无符号整型)
assign y_delta_small = {1'b0,y_delta_reg[7:5]};
assign y_delta_inv = 4'd8 - y_delta_small;

// 计算每个像素点的四个权重 (无符号整型计算)
wire    [3:0]               x_delta_small [15:0];
wire    [3:0]               x_delta_inv [15:0];  // 1 - x_delta, 只取低8位
(* use_dsp = "yes" *)  wire    [7:0]              weight_11_c [15:0];  // P到Q11权重(组合逻辑)
(* use_dsp = "yes" *)  wire    [7:0]              weight_12_c [15:0];  // P到Q12权重(组合逻辑)
(* use_dsp = "yes" *)  wire    [7:0]              weight_21_c [15:0];  // P到Q21权重(组合逻辑)
(* use_dsp = "yes" *)  wire    [7:0]              weight_22_c [15:0];  // P到Q22权重(组合逻辑)

// 权重寄存器
reg     [7:0]              weight_11 [15:0];  // P到Q11权重
reg     [7:0]              weight_12 [15:0];  // P到Q12权重
reg     [7:0]              weight_21 [15:0];  // P到Q21权重
reg     [7:0]              weight_22 [15:0];  // P到Q22权重

genvar k;
generate
    for (k = 0; k < 16; k = k + 1) begin: weight_calc
        // 1 - x_delta (只取低8位)
        // 只有当 k < data_valid 时才计算有效权重，否则为0
        
        assign x_delta_small[k] = (k < data_valid) ? {1'b0, x_delta_reg[k][7:5]} : 4'd0;
        assign x_delta_inv[k] = (k < data_valid) ? (4'd8 - x_delta_small[k]) : 4'd0;

        // w11 = (1-x) * (1-y) = x_delta_inv * y_delta_inv
        assign weight_11_c[k] = (k < data_valid) ? (x_delta_inv[k] * y_delta_inv) : 8'd0;

        // w12 = x * (1-y) = x_delta * y_delta_inv
        assign weight_12_c[k] = (k < data_valid) ? (x_delta_small[k] * y_delta_inv) : 8'd0;

        // w21 = (1-x) * y = x_delta_inv * y_delta
        assign weight_21_c[k] = (k < data_valid) ? (x_delta_inv[k] * y_delta_small) : 8'd0;

        // w22 = x * y = x_delta * y_delta
        assign weight_22_c[k] = (k < data_valid) ? (x_delta_small[k] * y_delta_small) : 8'd0;
    end
endgenerate

// ============================================================
// 根据x_delta_reg的高4位确定有效的输入索引
// x_delta_reg[k][14:11] 表示第k个输出像素对应的Q11点的列索引(0~15)
// ============================================================
wire    [3:0]               src_idx [15:0];  // 第k个输出像素对应的Q11源像素列索引

genvar idx;
generate
    for (idx = 0; idx < 16; idx = idx + 1) begin: src_idx_calc
        // 只有当 idx < data_valid 时才有有效的源像素索引
        assign src_idx[idx] = (idx < data_valid) ? x_delta_reg[idx][11:8] : 4'd0;
    end
endgenerate

// ============================================================
// 根据src_idx取有效的Q11、Q12、Q21、Q22点的像素值
// Q11: rs_regs[src_idx[idx]]     - 当前行，src_idx列
// Q12: rs_regs[src_idx[idx]+1]  - 当前行，src_idx+1列
// Q21: rs_regs_2[src_idx[idx]]   - 下一行，src_idx列
// Q22: rs_regs_2[src_idx[idx]+1]- 下一行，src_idx+1列
// ============================================================
// 像素值组合逻辑
wire    [31:0]              q11_val_c [15:0];  // Q11点像素值(组合逻辑)
wire    [31:0]              q12_val_c [15:0];  // Q12点像素值(组合逻辑)
wire    [31:0]              q21_val_c [15:0];  // Q21点像素值(组合逻辑)
wire    [31:0]              q22_val_c [15:0];  // Q22点像素值(组合逻辑)

// 像素值寄存器
reg     [31:0]              q11_val [15:0];  // Q11点像素值
reg     [31:0]              q12_val [15:0];  // Q12点像素值
reg     [31:0]              q21_val [15:0];  // Q21点像素值
reg     [31:0]              q22_val [15:0];  // Q22点像素值

genvar px;
generate
    for (px = 0; px < 16; px = px + 1) begin: pixel_idx
        // 只有当 px < data_valid 时才取有效像素值，否则为0
        // Q11: 当前行第src_idx[px]列
        assign q11_val_c[px] = (px < data_valid) ? rs_regs[src_idx[px]] : 32'd0;
        // Q12: 当前行第src_idx[px]+1列 (src_idx=15时钳位到像素15)
        assign q12_val_c[px] = (px < data_valid) ? rs_regs[(src_idx[px] < 15) ? (src_idx[px] + 4'd1) : 4'd15] : 32'd0;
        // Q21: 下一行第src_idx[px]列
        assign q21_val_c[px] = (px < data_valid) ? rs_regs_2[src_idx[px]] : 32'd0;
        // Q22: 下一行第src_idx[px]+1列 (src_idx=15时钳位到像素15)
        assign q22_val_c[px] = (px < data_valid) ? rs_regs_2[(src_idx[px] < 15) ? (src_idx[px] + 4'd1) : 4'd15] : 32'd0;
    end
endgenerate

// 在resize_status时寄存权重
genvar w;
generate
    for (w = 0; w < 16; w = w + 1) begin: weight_reg
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                weight_11[w] <= #0.1 6'd0;
                weight_12[w] <= #0.1 6'd0;
                weight_21[w] <= #0.1 6'd0;
                weight_22[w] <= #0.1 6'd0;
            end
            else if (resize_status) begin
                weight_11[w] <= #0.1 weight_11_c[w];
                weight_12[w] <= #0.1 weight_12_c[w];
                weight_21[w] <= #0.1 weight_21_c[w];
                weight_22[w] <= #0.1 weight_22_c[w];
            end
            else begin
                weight_11[w] <= #0.1 weight_11[w];
                weight_12[w] <= #0.1 weight_12[w];
                weight_21[w] <= #0.1 weight_21[w];
                weight_22[w] <= #0.1 weight_22[w];
            end
        end
    end
endgenerate

// 在resize_status时寄存像素值
genvar pv;
generate
    for (pv = 0; pv < 16; pv = pv + 1) begin: pixel_val_reg
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                q11_val[pv] <= #0.1 32'd0;
                q12_val[pv] <= #0.1 32'd0;
                q21_val[pv] <= #0.1 32'd0;
                q22_val[pv] <= #0.1 32'd0;
            end
            else if (resize_status) begin
                q11_val[pv] <= #0.1 q11_val_c[pv];
                q12_val[pv] <= #0.1 q12_val_c[pv];
                q21_val[pv] <= #0.1 q21_val_c[pv];
                q22_val[pv] <= #0.1 q22_val_c[pv];
            end
            else begin
                q11_val[pv] <= #0.1 q11_val[pv];
                q12_val[pv] <= #0.1 q12_val[pv];
                q21_val[pv] <= #0.1 q21_val[pv];
                q22_val[pv] <= #0.1 q22_val[pv];
            end
        end
    end
endgenerate

// ============================================================
// 第二级流水线：权重与像素值相乘
// P = Q11·w11 + Q12·w12 + Q21·w21 + Q22·w22
// 像素值格式: {R[7:0], G[7:0], B[7:0], 8'b0}
// ============================================================
// 乘法结果组合逻辑 - 按RGB三通道拆分
(* use_dsp = "yes" *) wire    [15:0]              result_11_r_c [15:0];  // Q11·w11_R通道
(* use_dsp = "yes" *) wire    [15:0]              result_11_g_c [15:0];  // Q11·w11_G通道
(* use_dsp = "yes" *) wire    [15:0]              result_11_b_c [15:0];  // Q11·w11_B通道
(* use_dsp = "yes" *) wire    [15:0]              result_12_r_c [15:0];  // Q12·w12_R通道
(* use_dsp = "yes" *) wire    [15:0]              result_12_g_c [15:0];  // Q12·w12_G通道
(* use_dsp = "yes" *) wire    [15:0]              result_12_b_c [15:0];  // Q12·w12_B通道
(* use_dsp = "yes" *) wire    [15:0]              result_21_r_c [15:0];  // Q21·w21_R通道
(* use_dsp = "yes" *) wire    [15:0]              result_21_g_c [15:0];  // Q21·w21_G通道
(* use_dsp = "yes" *) wire    [15:0]              result_21_b_c [15:0];  // Q21·w21_B通道
(* use_dsp = "yes" *) wire    [15:0]              result_22_r_c [15:0];  // Q22·w22_R通道
(* use_dsp = "yes" *) wire    [15:0]              result_22_g_c [15:0];  // Q22·w22_G通道
(* use_dsp = "yes" *) wire    [15:0]              result_22_b_c [15:0];  // Q22·w22_B通道

// 乘法结果寄存器
reg     [15:0]              result_11_r [15:0];  // Q11·w11_R通道
reg     [15:0]              result_11_g [15:0];  // Q11·w11_G通道
reg     [15:0]              result_11_b [15:0];  // Q11·w11_B通道
reg     [15:0]              result_12_r [15:0];  // Q12·w12_R通道
reg     [15:0]              result_12_g [15:0];  // Q12·w12_G通道
reg     [15:0]              result_12_b [15:0];  // Q12·w12_B通道
reg     [15:0]              result_21_r [15:0];  // Q21·w21_R通道
reg     [15:0]              result_21_g [15:0];  // Q21·w21_G通道
reg     [15:0]              result_21_b [15:0];  // Q21·w21_B通道
reg     [15:0]              result_22_r [15:0];  // Q22·w22_R通道
reg     [15:0]              result_22_g [15:0];  // Q22·w22_G通道
reg     [15:0]              result_22_b [15:0];  // Q22·w22_B通道

genvar m;
generate
    for (m = 0; m < 16; m = m + 1) begin: multiply_stage
        // Q11 三个通道分别乘以权重
        assign result_11_r_c[m] = q11_val[m][23:16] * weight_11[m];
        (* use_dsp = "yes" *) assign result_11_g_c[m] = q11_val[m][15:8] * weight_11[m];
        (* use_dsp = "yes" *) assign result_11_b_c[m] = q11_val[m][7:0] * weight_11[m];
        // Q12 三个通道分别乘以权重
        (* use_dsp = "yes" *) assign result_12_r_c[m] = q12_val[m][23:16] * weight_12[m];
        (* use_dsp = "yes" *) assign result_12_g_c[m] = q12_val[m][15:8] * weight_12[m];
        (* use_dsp = "yes" *) assign result_12_b_c[m] = q12_val[m][7:0] * weight_12[m];
        // Q21 三个通道分别乘以权重
        (* use_dsp = "yes" *) assign result_21_r_c[m] = q21_val[m][23:16] * weight_21[m];
        (* use_dsp = "yes" *) assign result_21_g_c[m] = q21_val[m][15:8] * weight_21[m];
        (* use_dsp = "yes" *) assign result_21_b_c[m] = q21_val[m][7:0] * weight_21[m];
        // Q22 三个通道分别乘以权重
        (* use_dsp = "yes" *) assign result_22_r_c[m] = q22_val[m][23:16] * weight_22[m];
        (* use_dsp = "yes" *) assign result_22_g_c[m] = q22_val[m][15:8] * weight_22[m];
        (* use_dsp = "yes" *) assign result_22_b_c[m] = q22_val[m][7:0] * weight_22[m];
    end
endgenerate

// 在resize_status时寄存乘法结果
genvar r;
generate
    for (r = 0; r < 16; r = r + 1) begin: result_reg
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                result_11_r[r] <= #0.1 16'd0;
                result_11_g[r] <= #0.1 16'd0;
                result_11_b[r] <= #0.1 16'd0;
                result_12_r[r] <= #0.1 16'd0;
                result_12_g[r] <= #0.1 16'd0;
                result_12_b[r] <= #0.1 16'd0;
                result_21_r[r] <= #0.1 16'd0;
                result_21_g[r] <= #0.1 16'd0;
                result_21_b[r] <= #0.1 16'd0;
                result_22_r[r] <= #0.1 16'd0;
                result_22_g[r] <= #0.1 16'd0;
                result_22_b[r] <= #0.1 16'd0;
            end
            else if (resize_status) begin
                result_11_r[r] <= #0.1 result_11_r_c[r];
                result_11_g[r] <= #0.1 result_11_g_c[r];
                result_11_b[r] <= #0.1 result_11_b_c[r];
                result_12_r[r] <= #0.1 result_12_r_c[r];
                result_12_g[r] <= #0.1 result_12_g_c[r];
                result_12_b[r] <= #0.1 result_12_b_c[r];
                result_21_r[r] <= #0.1 result_21_r_c[r];
                result_21_g[r] <= #0.1 result_21_g_c[r];
                result_21_b[r] <= #0.1 result_21_b_c[r];
                result_22_r[r] <= #0.1 result_22_r_c[r];
                result_22_g[r] <= #0.1 result_22_g_c[r];
                result_22_b[r] <= #0.1 result_22_b_c[r];
            end
            else begin
                result_11_r[r] <= #0.1 result_11_r[r];
                result_11_g[r] <= #0.1 result_11_g[r];
                result_11_b[r] <= #0.1 result_11_b[r];
                result_12_r[r] <= #0.1 result_12_r[r];
                result_12_g[r] <= #0.1 result_12_g[r];
                result_12_b[r] <= #0.1 result_12_b[r];
                result_21_r[r] <= #0.1 result_21_r[r];
                result_21_g[r] <= #0.1 result_21_g[r];
                result_21_b[r] <= #0.1 result_21_b[r];
                result_22_r[r] <= #0.1 result_22_r[r];
                result_22_g[r] <= #0.1 result_22_g[r];
                result_22_b[r] <= #0.1 result_22_b[r];
            end
        end
    end
endgenerate

// ============================================================
// 第三级流水线：四个加权像素值按通道相加
// P = Q11·w11 + Q12·w12 + Q21·w21 + Q22·w22
// 直接取加权值的高8位相加，得到最终8位像素值
// ============================================================
    // 加法结果: 全精度[13:0]求和, 再右移6位(÷64权重归一化), 取8位输出
    wire    [15:0]              sum_r_full [15:0];  // R通道全精度和 (4×14bit → 16bit)
    wire    [15:0]              sum_g_full [15:0];  // G通道全精度和
    wire    [15:0]              sum_b_full [15:0];  // B通道全精度和
    wire    [7:0]               result_r_c [15:0];  // R通道最终结果
    wire    [7:0]               result_g_c [15:0];  // G通道最终结果
    wire    [7:0]               result_b_c [15:0];  // B通道最终结果

    // 最终像素值寄存器 {R, G, B, 8'b0}
    reg     [31:0]              result_val [15:0];  // 最终插值结果

    genvar a;
    generate
        for (a = 0; a < 16; a = a + 1) begin: add_stage
            // 全精度求和 (保留低位进位)
            assign sum_r_full[a] = result_11_r[a] + result_12_r[a]
                                 + result_21_r[a] + result_22_r[a];
            assign sum_g_full[a] = result_11_g[a] + result_12_g[a]
                                 + result_21_g[a] + result_22_g[a];
            assign sum_b_full[a] = result_11_b[a] + result_12_b[a]
                                 + result_21_b[a] + result_22_b[a];
            // 右移6位 (÷64权重归一化), 取8位
            assign result_r_c[a] = sum_r_full[a][13:6];
            assign result_g_c[a] = sum_g_full[a][13:6];
            assign result_b_c[a] = sum_b_full[a][13:6];
        end
    endgenerate

// 在resize_status时寄存最终结果
genvar s;
generate
    for (s = 0; s < 16; s = s + 1) begin: result_val_reg
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                result_val[s] <= #0.1 32'd0;
            end
            else if (resize_status) begin
                result_val[s] <= #0.1 {8'b0,result_r_c[s][7:0], result_g_c[s][7:0], result_b_c[s][7:0]};
            end
            else begin
                result_val[s] <= #0.1 result_val[s];
            end
        end
    end
endgenerate

assign din_ready = trans_status[0];

// ============ FIFO 输出路径 ============
// FIFO 读使能: 写通道激活 + FIFO 有足够数据 + 未在读
assign fifo_rd_en = trans_status[1] && fifo_flush_ready && !fifo_rd_valid;

// FIFO force_rd: comp_done 后强制排出残余像素 (<16)
wire force_rd;
reg  comp_done_reg;
wire comp_done_pos;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        comp_done_reg <= #0.1 1'b0;
    end
    else begin
        comp_done_reg <= #0.1 comp_done;
    end
end
assign comp_done_pos = comp_done & ~comp_done_reg;
assign force_rd = (comp_done_pos || fifo_drain) && !fifo_empty && !fifo_flush_ready;

// dout 从 FIFO 读取 (替代原来的 result_val 拼接)
// 保持 dout_valid 直到 DMA 握手完成 (dout_ready 拉高)
reg dout_hold;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        dout_hold <= #0.1 1'b0;
    else if (fifo_rd_valid && trans_status[1])
        dout_hold <= #0.1 1'b1;
    else if (dout_hold && dout_ready)
        dout_hold <= #0.1 1'b0;
end

assign dout_rs = fifo_rd_data;
assign dout_valid_rs  = dout_hold;
assign resize_done = result_valid;

// 实例化 AVR 寄存器切片模块 (avr_rs)
avr_rs #(.DW(512)) U_avr_rs(
    .m_data      ( dout_rs         ),
    .m_valid     ( dout_valid_rs   ),
    .m_ready     ( dout_ready_rs   ),

    .s_data      ( dout            ),
    .s_valid     ( dout_valid      ),
    .s_ready     ( dout_ready      ),

    .clk         ( clk            ),
    .rst_n       ( rst_n          )
);

// ============ 例化 resize_fifo ============
resize_fifo #(
    .FIFO_DEPTH(32),
    .PIXEL_W(32)
) U_RESIZE_FIFO (
    .clk            ( clk            ),
    .rst_n          ( rst_n          ),
    .batch_wr_en    ( batch_wr_en    ),
    .batch_wr_data  ( batch_wr_data  ),
    .batch_wr_count ( batch_wr_count ),
    .rd_en          ( fifo_rd_en     ),
    .force_rd    ( force_rd       ),
    .rd_data     ( fifo_rd_data   ),
    .rd_valid    ( fifo_rd_valid  ),
    .fifo_cnt    ( fifo_cnt       ),
    .flush_ready ( fifo_flush_ready ),
    .fifo_empty  ( fifo_empty     ),
    .fifo_full   ( fifo_full      )
);


endmodule
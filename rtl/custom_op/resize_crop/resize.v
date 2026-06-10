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
        if (resize_status && resize_cycle == 3'd5)
            result_valid <= #0.1 1'b1;
        else if (resize_status_negedge)
            result_valid <= #0.1 1'b0;
        else
            result_valid <= #0.1 result_valid;
    end
end
assign result_valid_pos = result_valid & ~result_valid_reg;

// ============ 流水线交织 pass 控制 (2-bit, 4 pass, 6 周期) ============
// pass_s1→Stage1(像素/权重), pass_s2→Stage2(DSP), pass_s3→Stage3(输出)
reg [2:0] resize_cycle;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        resize_cycle <= #0.1 3'd0;
    else if (resize_status)
        resize_cycle <= #0.1 resize_cycle + 3'd1;
    else
        resize_cycle <= #0.1 3'd0;
end

reg [1:0] pass_s1, pass_s2, pass_s3;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pass_s1 <= #0.1 2'd0; pass_s2 <= #0.1 2'd0; pass_s3 <= #0.1 2'd0;
    end
    else if (!resize_status) begin
        pass_s1 <= #0.1 2'd0; pass_s2 <= #0.1 2'd0; pass_s3 <= #0.1 2'd0;
    end
    else begin
        pass_s1 <= #0.1 (resize_cycle < 3'd4) ? resize_cycle[1:0] : pass_s1;
        pass_s2 <= #0.1 pass_s1;
        pass_s3 <= #0.1 pass_s2;
    end
end

wire [3:0] px_base = {pass_s1, 2'b0};   // 0, 4, 8, 12 per pass

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
wire    [7:0]              weight_11_c [15:0];  // P到Q11权重(组合逻辑, 4b×4b→LUT)
wire    [7:0]              weight_12_c [15:0];  // P到Q12权重(组合逻辑)
wire    [7:0]              weight_21_c [15:0];  // P到Q21权重(组合逻辑)
wire    [7:0]              weight_22_c [15:0];  // P到Q22权重(组合逻辑)

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
// 像素值组合逻辑 (4 像素, 由 pass_s1 选组)
wire    [31:0]              q11_val_c [3:0];
wire    [31:0]              q12_val_c [3:0];
wire    [31:0]              q21_val_c [3:0];
wire    [31:0]              q22_val_c [3:0];

// 像素值寄存器 (16 像素全宽, 保持)
reg     [31:0]              q11_val [15:0];
reg     [31:0]              q12_val [15:0];
reg     [31:0]              q21_val [15:0];
reg     [31:0]              q22_val [15:0];

genvar px;
generate
    for (px = 0; px < 4; px = px + 1) begin: pixel_idx
        wire [3:0] px_full = px_base + px[1:0];
        wire       is_valid = (px_full < data_valid);
        assign q11_val_c[px] = is_valid ? rs_regs[src_idx[px_full]] : 32'd0;
        assign q12_val_c[px] = is_valid ? rs_regs[(src_idx[px_full] < 15) ? (src_idx[px_full] + 4'd1) : 4'd15] : 32'd0;
        assign q21_val_c[px] = is_valid ? rs_regs_2[src_idx[px_full]] : 32'd0;
        assign q22_val_c[px] = is_valid ? rs_regs_2[(src_idx[px_full] < 15) ? (src_idx[px_full] + 4'd1) : 4'd15] : 32'd0;
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

// 在resize_status时寄存像素值 (4 像素, 按 pass_s1 写入对应组)
genvar pv;
generate
    for (pv = 0; pv < 16; pv = pv + 1) begin: pixel_val_reg
        wire [1:0] pv_group = pv[3:2];
        wire       this_pass = (pv_group == pass_s1);
        wire [1:0] sub_idx  = pv[1:0];
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                q11_val[pv] <= #0.1 32'd0;
                q12_val[pv] <= #0.1 32'd0;
                q21_val[pv] <= #0.1 32'd0;
                q22_val[pv] <= #0.1 32'd0;
            end
            else if (resize_status && this_pass) begin
                q11_val[pv] <= #0.1 q11_val_c[sub_idx];
                q12_val[pv] <= #0.1 q12_val_c[sub_idx];
                q21_val[pv] <= #0.1 q21_val_c[sub_idx];
                q22_val[pv] <= #0.1 q22_val_c[sub_idx];
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
// 第二级流水线：权重与像素值相乘 (4 像素, R/G DSP 打包)
// A = {1'b0, R, 8'b0, G} = R×2^16 + G,  B = weight
// 乘积: A×B = R×w×2^16 + G×w,  两通道无重叠
// ============================================================
// R+G 打包乘法结果 (32-bit, 4 邻居 × 4 像素)
(* use_dsp = "yes" *) wire [31:0] result_RG_11_c [3:0];
(* use_dsp = "yes" *) wire [31:0] result_RG_12_c [3:0];
(* use_dsp = "yes" *) wire [31:0] result_RG_21_c [3:0];
(* use_dsp = "yes" *) wire [31:0] result_RG_22_c [3:0];
(* use_dsp = "yes" *) wire [15:0] result_B_11_c  [3:0];
(* use_dsp = "yes" *) wire [15:0] result_B_12_c  [3:0];
(* use_dsp = "yes" *) wire [15:0] result_B_21_c  [3:0];
(* use_dsp = "yes" *) wire [15:0] result_B_22_c  [3:0];

// R+G 打包乘法结果寄存器
reg [31:0] result_RG_11 [3:0];
reg [31:0] result_RG_12 [3:0];
reg [31:0] result_RG_21 [3:0];
reg [31:0] result_RG_22 [3:0];
// B 通道结果寄存器
reg [15:0] result_B_11  [3:0];
reg [15:0] result_B_12  [3:0];
reg [15:0] result_B_21  [3:0];
reg [15:0] result_B_22  [3:0];

// 直接索引: {pass_s2, sub_idx} 替代 group_sel MUX 树
wire [3:0] dsp_idx [3:0];
genvar gs;
generate
    for (gs = 0; gs < 4; gs = gs + 1) begin: dsp_idx_gen
        assign dsp_idx[gs] = {pass_s2, gs[1:0]};
    end
endgenerate

genvar m;
generate
    for (m = 0; m < 4; m = m + 1) begin: multiply_stage
        wire [23:0] A_RG_11 = {1'b0, q11_val[dsp_idx[m]][23:16], 8'b0, q11_val[dsp_idx[m]][15:8]};
        wire [23:0] A_RG_12 = {1'b0, q12_val[dsp_idx[m]][23:16], 8'b0, q12_val[dsp_idx[m]][15:8]};
        wire [23:0] A_RG_21 = {1'b0, q21_val[dsp_idx[m]][23:16], 8'b0, q21_val[dsp_idx[m]][15:8]};
        wire [23:0] A_RG_22 = {1'b0, q22_val[dsp_idx[m]][23:16], 8'b0, q22_val[dsp_idx[m]][15:8]};
        assign result_RG_11_c[m] = A_RG_11 * weight_11[dsp_idx[m]];
        assign result_RG_12_c[m] = A_RG_12 * weight_12[dsp_idx[m]];
        assign result_RG_21_c[m] = A_RG_21 * weight_21[dsp_idx[m]];
        assign result_RG_22_c[m] = A_RG_22 * weight_22[dsp_idx[m]];
        assign result_B_11_c[m]  = q11_val[dsp_idx[m]][7:0] * weight_11[dsp_idx[m]];
        assign result_B_12_c[m]  = q12_val[dsp_idx[m]][7:0] * weight_12[dsp_idx[m]];
        assign result_B_21_c[m]  = q21_val[dsp_idx[m]][7:0] * weight_21[dsp_idx[m]];
        assign result_B_22_c[m]  = q22_val[dsp_idx[m]][7:0] * weight_22[dsp_idx[m]];
    end
endgenerate

// 在resize_status时寄存乘法结果
genvar r;
generate
    for (r = 0; r < 4; r = r + 1) begin: result_reg
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                result_RG_11[r] <= #0.1 32'd0;
                result_RG_12[r] <= #0.1 32'd0;
                result_RG_21[r] <= #0.1 32'd0;
                result_RG_22[r] <= #0.1 32'd0;
                result_B_11[r]  <= #0.1 16'd0;
                result_B_12[r]  <= #0.1 16'd0;
                result_B_21[r]  <= #0.1 16'd0;
                result_B_22[r]  <= #0.1 16'd0;
            end
            else if (resize_status) begin
                result_RG_11[r] <= #0.1 result_RG_11_c[r];
                result_RG_12[r] <= #0.1 result_RG_12_c[r];
                result_RG_21[r] <= #0.1 result_RG_21_c[r];
                result_RG_22[r] <= #0.1 result_RG_22_c[r];
                result_B_11[r]  <= #0.1 result_B_11_c[r];
                result_B_12[r]  <= #0.1 result_B_12_c[r];
                result_B_21[r]  <= #0.1 result_B_21_c[r];
                result_B_22[r]  <= #0.1 result_B_22_c[r];
            end
            else begin
                result_RG_11[r] <= #0.1 result_RG_11[r];
                result_RG_12[r] <= #0.1 result_RG_12[r];
                result_RG_21[r] <= #0.1 result_RG_21[r];
                result_RG_22[r] <= #0.1 result_RG_22[r];
                result_B_11[r]  <= #0.1 result_B_11[r];
                result_B_12[r]  <= #0.1 result_B_12[r];
                result_B_21[r]  <= #0.1 result_B_21[r];
                result_B_22[r]  <= #0.1 result_B_22[r];
            end
        end
    end
endgenerate

// ============================================================
// 第三级流水线：四个加权像素值按通道相加 (4 像素, RG 打包)
// sum_RG = Σ(R×w)×2^16 + Σ(G×w)
// R 提取: sum_RG[29:22], G 提取: sum_RG[13:6]
// ============================================================
    wire    [31:0]              sum_RG_full [3:0];   // R+G 打包全精度和
    wire    [15:0]              sum_B_full  [3:0];   // B 通道全精度和
    wire    [7:0]               result_r_c [3:0];    // R 通道最终结果
    wire    [7:0]               result_g_c [3:0];    // G 通道最终结果
    wire    [7:0]               result_b_c [3:0];    // B 通道最终结果

    reg     [31:0]              result_val [15:0];   // 最终插值结果

    genvar a;
    generate
        for (a = 0; a < 4; a = a + 1) begin: add_stage
            assign sum_RG_full[a] = result_RG_11[a] + result_RG_12[a]
                                  + result_RG_21[a] + result_RG_22[a];
            assign sum_B_full[a]  = result_B_11[a]  + result_B_12[a]
                                  + result_B_21[a]  + result_B_22[a];
            assign result_r_c[a] = sum_RG_full[a][29:22];
            assign result_g_c[a] = sum_RG_full[a][13:6];
            assign result_b_c[a] = sum_B_full[a][13:6];
        end
    endgenerate

// 在resize_status时寄存最终结果 (按 pass_s3 写入对应组)
genvar s;
generate
    for (s = 0; s < 16; s = s + 1) begin: result_val_reg
        wire [1:0] s_group   = s[3:2];
        wire       this_pass = (s_group == pass_s3);
        wire [1:0] sub_idx   = s[1:0];
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                result_val[s] <= #0.1 32'd0;
            end
            else if (resize_status && this_pass) begin
                result_val[s] <= #0.1 {8'b0, result_r_c[sub_idx], result_g_c[sub_idx], result_b_c[sub_idx]};
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
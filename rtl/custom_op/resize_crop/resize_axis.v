module resize_axis (
    // 来自FSM的控制信号
    input               axis_pre_cal,       // 预计算信号,计算裁剪区域和缩放比例
    input               axis_cal_status,    // 轴计算状态激活 (来自resize_fsm)
    input               resize_status,      // Resize操作状态激活 (来自resize_fsm)
    input       [1:0]   trans_status,       // 传输状态 (来自resize_fsm)
    input       [15:0]  resize_ratio_less,
    input       [15:0]  resize_ratio_greater,

    // 裁剪控制
    input               crop_enable,         // 裁剪使能

    // 来自寄存器的图像尺寸
    input       [15:0] rwidth_rs,          // 读宽度
    input       [15:0] rheight_rs,          // 读高度
    input       [15:0] wwidth_rs,           // 写宽度
    input       [15:0] wheight_rs,          // 写高度

    // 裁剪参数输出 (传给 resize_addr_gen / resize)
    output reg  [15:0]  crop_size,          // 正方形边长
    output reg  [15:0]  crop_off_x,         // 水平偏移 (像素)
    output reg  [15:0]  crop_off_y,         // 垂直偏移 (像素)

    // 输出: 目标像素的坐标映射
    output reg  [7:0]   data_valid,          // 16个数据中的有效个数

    output reg  [255:0] x_delta,          //  P点相对于起始原像素的x偏移
    output reg  [7:0]   y_delta,          //  P点相对于下一行的y偏移
    output reg  [15:0]  y_bias,           //  y轴偏移量对应的行

    // 完成信号给FSM
    output             axis_done,           // 轴计算完成
    output             axis_pre_cal_done,    // 预计算完成

    // 时钟和复位
    input              clk,
    input              rst_n
);


    reg [15:0] width_ratio_less;     // Q1.3.12格式, w/r < 1
    reg [15:0] height_ratio_less;   // Q1.3.12格式, h/r < 1
    reg [15:0] width_ratio_greater; // Q1.7.8格式, r/w > 1
    reg [15:0] height_ratio_greater;// Q1.7.8格式, r/h > 1
    reg        axis_pre_cal_done_r;

    // ============ 裁剪参数计算 (axis_cal_status 激活时) ============
    wire [15:0] crop_size_w = crop_enable
        ? ((rwidth_rs < rheight_rs) ? rwidth_rs : rheight_rs)
        : rwidth_rs;
    wire [15:0] crop_off_x_w = crop_enable ? ((rwidth_rs  - crop_size_w) >> 1) : 16'd0;
    wire [15:0] crop_off_y_w = crop_enable ? ((rheight_rs - crop_size_w) >> 1) : 16'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crop_size  <= 16'd0;
            crop_off_x <= 16'd0;
            crop_off_y <= 16'd0;
        end
        else if (axis_pre_cal) begin
            crop_size  <= crop_size_w;
            crop_off_x <= crop_off_x_w;
            crop_off_y <= crop_off_y_w;
        end
    end

    // 预计算: 缩放比例
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            width_ratio_less <= #0.1 16'd0;
            height_ratio_less <= #0.1 16'd0;
            width_ratio_greater <= #0.1 16'd0;
            height_ratio_greater <= #0.1 16'd0;
            axis_pre_cal_done_r <= #0.1 1'b0;
        end
        else if (axis_pre_cal) begin
            width_ratio_less <= #0.1 resize_ratio_less;
            height_ratio_less <= #0.1 resize_ratio_less;
            width_ratio_greater <= #0.1 resize_ratio_greater;
            height_ratio_greater <= #0.1 resize_ratio_greater;
            axis_pre_cal_done_r <= #0.1 1'b1;
        end
        else begin
            width_ratio_less <= #0.1 width_ratio_less;
            height_ratio_less <= #0.1 height_ratio_less;
            width_ratio_greater <= #0.1 width_ratio_greater;
            height_ratio_greater <= #0.1 height_ratio_greater;
            axis_pre_cal_done_r <= #0.1 axis_pre_cal_done_r;
        end
    end

    assign axis_pre_cal_done = axis_pre_cal_done_r;

    // ============ 轴计算阶段 (axis_cal_status) ============
    // 两级流水线设计:
    // 第一级: 计算width_ratio_greater*i, y_delta, y_bias, next_bias的乘法
    // 第二级: 计算width_ratio_greater*i - pre_bias
    //
    // 定点数格式说明:
    //   ratioed_y_full = height_ratio_greater(Q1.7.8) * current_row_y(INT16)
    //       32-bit Q1.23.8: bit[31]=sign, bit[30:8]=integer(23b), bit[7:0]=fraction(8b)
    //   ratioed_x_full = width_ratio_less(Q1.3.12) * ratioed_x_full_add_r(Q1.7.8)
    //       32-bit: bit[31]=sign, bit[30:20]=integer, bit[19:0]=fraction
    //       ratioed_x_full[27:12] → 16-bit Q1.7.8 (8 integer + 8 fraction)
    //   x_delta_reg[k] = 16-bit Q1.7.8: bit[15]=sign, bit[14:8]=integer(7b), bit[7:0]=fraction(8b)
    //       resize.v 中 src_idx 应取 bit[11:8]=integer mod 16 (=块内列索引)
    //       x_delta_small 取 bit[7:5]=fraction高3b (权重计算用)

    // 当前行y坐标寄存器
    reg     [15:0] current_row_y;   // INT16格式

    // 当前行像素计数器
    reg     [15:0] pixel_cnt;
    reg     [15:0] pre_bias;        // Q1.7.8格式
    wire    [31:0] ratioed_x_full;
    wire    [31:0] ratioed_x_full_add;
    wire    [15:0] ratioed_x;       // Q1.7.8格式
    wire    [31:0] ratioed_y_full;  // Q1.23.8: bit[31]=sign, bit[30:8]=int, bit[7:0]=frac
    wire    [15:0] pixel_cnt_next;

    // 有符号运算 (pre_bias 可能为负)
    wire signed [16:0] pre_bias_s;
    wire signed [16:0] const_16s;
    wire signed [16:0] ratioed_x_full_add_s;

    // 第一级流水线计算结果 (combinational)
    wire    [255:0] x_delta_mul;    // width_ratio_greater * i 结果
    wire    [23:0] next_bias_mul;   // next_bias 乘法结果
    wire    [7:0]  y_delta_next;    // y_delta 下一值
    wire    [15:0] y_bias_next;     // y_bias 下一值
    wire    [15:0] current_row_y_next; // current_row_y 下一值

    // 第一级流水线寄存器 (sequential) - 锁存第一级计算结果
    reg     [31:0] ratioed_x_full_add_r;
    reg     [31:0] ratioed_y_full_r;
    reg     [255:0] x_delta_mul_r;
    reg     [15:0] next_bias_mul_r;
    reg     [7:0]  y_delta_next_r;
    reg     [15:0] y_bias_next_r;
    reg     [15:0] current_row_y_next_r;
    reg     [15:0] pixel_cnt_next_r;

    // 第二级流水线计算结果 (combinational)
    wire    [255:0] x_delta_sub;    // width_ratio_greater * i - pre_bias 结果
    wire    [15:0] pre_bias_next;   // 下一周期 pre_bias
    wire    axis_cal_negedge;       // axis_cal_status 下降沿检测
    wire    axis_cal_negedge1;

    // ============ 第一级计算 ============
    // (16 + pre_bias): Q1.7.8格式, pre_bias 可能为负 → 必须用有符号加法
    assign pre_bias_s = {pre_bias[15], pre_bias};
    assign const_16s  = {1'b0, 7'd16, 8'd0};
    assign ratioed_x_full_add_s = const_16s + pre_bias_s;
    assign ratioed_x_full_add = {15'd0, ratioed_x_full_add_s};
    //Q1.23.8格式
    assign ratioed_y_full = height_ratio_greater * current_row_y - {23'b0,1'b1,8'b0}; 
    assign pixel_cnt_next = pixel_cnt + 16;

    // x_delta_mul[i] = width_ratio_greater(Q1.7.8) * i  (i=1..16)
    // resize.v中: src_idx应取 x_delta_reg[k][11:8] (整数 mod 16, 块内列索引)
    //           x_delta_small应取 x_delta_reg[k][7:5] (fraction高3b, 权重用)
    // 第一级: 计算16个乘法 width_ratio_greater * i
    assign x_delta_mul[15:0]   = width_ratio_greater    ;
    assign x_delta_mul[31:16]  = width_ratio_greater * 2;
    assign x_delta_mul[47:32]  = width_ratio_greater * 3;
    assign x_delta_mul[63:48]  = width_ratio_greater * 4;
    assign x_delta_mul[79:64]  = width_ratio_greater * 5;
    assign x_delta_mul[95:80]  = width_ratio_greater * 6;
    assign x_delta_mul[111:96] = width_ratio_greater * 7;
    assign x_delta_mul[127:112]= width_ratio_greater * 8;
    assign x_delta_mul[143:128]= width_ratio_greater * 9;
    assign x_delta_mul[159:144]= width_ratio_greater * 10;
    assign x_delta_mul[175:160]= width_ratio_greater * 11;
    assign x_delta_mul[191:176]= width_ratio_greater * 12;
    assign x_delta_mul[207:192]= width_ratio_greater * 13;
    assign x_delta_mul[223:208]= width_ratio_greater * 14;
    assign x_delta_mul[239:224]= width_ratio_greater * 15;
    assign x_delta_mul[255:240]= width_ratio_greater * 16;

    // y_delta: ratioed_y_full Q1.23.8 fraction在 bit[7:0]
    // y_bias:  ratioed_y_full Q1.23.8 integer在 bit[30:8]
    // 第一级: y_delta, y_bias, current_row_y, next_bias乘法
    assign y_delta_next = (pixel_cnt == 16'b0) ? ratioed_y_full[7:0] : y_delta;
    assign y_bias_next = (pixel_cnt == 16'b0) ? ratioed_y_full[23:8] : y_bias;
    assign current_row_y_next = (pixel_cnt_next == crop_size) ? current_row_y + 1 : current_row_y;

    // ============ 第二级计算 ============
    // 第二级: 使用第一级锁存结果计算 width_ratio_greater * i - pre_bias
    assign x_delta_sub[15:0]   = x_delta_mul_r[15:0]   - pre_bias - 16'b1;
    assign x_delta_sub[31:16]  = x_delta_mul_r[31:16]  - pre_bias - 16'b1;
    assign x_delta_sub[47:32]  = x_delta_mul_r[47:32]  - pre_bias - 16'b1;
    assign x_delta_sub[63:48]  = x_delta_mul_r[63:48]  - pre_bias - 16'b1;
    assign x_delta_sub[79:64]  = x_delta_mul_r[79:64]  - pre_bias - 16'b1;
    assign x_delta_sub[95:80]  = x_delta_mul_r[95:80]  - pre_bias - 16'b1;
    assign x_delta_sub[111:96] = x_delta_mul_r[111:96] - pre_bias - 16'b1;
    assign x_delta_sub[127:112]= x_delta_mul_r[127:112]- pre_bias - 16'b1;
    assign x_delta_sub[143:128]= x_delta_mul_r[143:128]- pre_bias - 16'b1;
    assign x_delta_sub[159:144]= x_delta_mul_r[159:144]- pre_bias - 16'b1;
    assign x_delta_sub[175:160]= x_delta_mul_r[175:160]- pre_bias - 16'b1;
    assign x_delta_sub[191:176]= x_delta_mul_r[191:176]- pre_bias - 16'b1;
    assign x_delta_sub[207:192]= x_delta_mul_r[207:192]- pre_bias - 16'b1;
    assign x_delta_sub[223:208]= x_delta_mul_r[223:208]- pre_bias - 16'b1;
    assign x_delta_sub[239:224]= x_delta_mul_r[239:224]- pre_bias - 16'b1;
    assign x_delta_sub[255:240]= x_delta_mul_r[255:240]- pre_bias - 16'b1;

    // next_bias: width_ratio_greater(Q1.7.8) * data_valid(=ratioed_x[15:8], integer part)
    wire [23:0] next_bias_mul_comb ;
    assign next_bias_mul_comb = width_ratio_greater * data_valid_int;
    // pre_bias_next = 16.0 + pre_bias - next_bias_mul_r (累积前序 pre_bias)
    wire signed [16:0] pre_bias_next_s;
    assign pre_bias_next_s = (pixel_cnt_next_r == crop_size) ? 17'd0 :
                              const_16s + pre_bias_s - $signed({1'b0, next_bias_mul_r});
    assign pre_bias_next = pre_bias_next_s[15:0];
    assign ratioed_x_full = width_ratio_less * ratioed_x_full_add_r + {20'b0,1'b1,12'b0};
    assign ratioed_x = ratioed_x_full[27:12];  // 截取16bit → Q1.7.8 (bit[15:8]=integer, bit[7:0]=fraction)

    // 添加nudge值(+0.5 = +8'h80 in Q1.7.8), 再钳位 0~16
    wire [15:0] ratioed_x_rnd = ratioed_x;
    wire [7:0] data_valid_int = (ratioed_x_rnd[15:8] > 8'd16) ? 8'd16 : ratioed_x_rnd[15:8];

    // ============ 流水线寄存器更新 ============
    // 第一级流水线寄存器: 锁存第一级乘法计算结果
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            ratioed_x_full_add_r <= #0.1 32'd0;
            ratioed_y_full_r <= #0.1 32'd0;
            x_delta_mul_r <= #0.1 256'd0;
            y_delta_next_r <= #0.1 8'd0;
            y_bias_next_r <= #0.1 16'd0;
            current_row_y_next_r <= #0.1 16'd0;
            pixel_cnt_next_r <= #0.1 16'd0;
        end
        else if(axis_cal_status) begin
            // 第一级计算结果锁存到寄存器
            ratioed_x_full_add_r <= #0.1 ratioed_x_full_add;
            ratioed_y_full_r <= #0.1 ratioed_y_full;
            x_delta_mul_r <= #0.1 x_delta_mul;
            y_delta_next_r <= #0.1 y_delta_next;
            y_bias_next_r <= #0.1 y_bias_next;
            current_row_y_next_r <= #0.1 current_row_y_next;
            pixel_cnt_next_r <= #0.1 pixel_cnt_next;
        end
    end

    // 第二级流水线寄存器: 锁存第二级计算结果到输出
    // axis_cal_status 延迟寄存器用于检测下降沿
    reg axis_cal_status_reg;
    reg axis_cal_status_reg1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            axis_cal_status_reg <= #0.1 1'b0;
            axis_cal_status_reg1 <= #0.1 1'b0;
        end
        else begin
            axis_cal_status_reg <= #0.1 axis_cal_status;
            axis_cal_status_reg1 <= #0.1 axis_cal_status_reg;
        end
    end
    assign axis_cal_negedge = ~axis_cal_status & axis_cal_status_reg;  // 下降沿检测
    assign axis_cal_negedge1 = ~axis_cal_status_reg & axis_cal_status_reg1;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            data_valid <= #0.1 8'd0;
            x_delta <= #0.1 256'd0;
            y_delta <= #0.1 8'd0;
            pixel_cnt <= #0.1 16'd0;
            current_row_y <= #0.1 16'd1; //初始即需要缩放
            y_bias <= #0.1 16'd0;
            next_bias_mul_r <= #0.1 16'd0;
            pre_bias <= #0.1 16'd0;
        end
        else begin
            if(axis_cal_negedge) begin
                // Stage2 输出: axis_cal_status 下降沿触发, 精确一次
                data_valid <= data_valid_int;
                x_delta <= #0.1 x_delta_sub;
                y_delta <= #0.1 y_delta_next_r;
                y_bias <= #0.1 y_bias_next_r;
                current_row_y <= #0.1 current_row_y_next_r;
                pixel_cnt <= #0.1 (pixel_cnt_next_r == crop_size) ? 16'b0 : pixel_cnt_next_r;
                next_bias_mul_r <= #0.1 next_bias_mul_comb;
                pre_bias <= #0.1 pre_bias;
            end
            else if(axis_cal_negedge1) begin
                // 更新 pre_bias (使用上一周期锁存的 next_bias_mul_r)
                pre_bias <= #0.1 pre_bias_next;
                next_bias_mul_r <= #0.1 next_bias_mul_r;
                data_valid <= #0.1 data_valid;
                x_delta <= #0.1 x_delta;
                y_delta <= #0.1 y_delta;
                pixel_cnt <= #0.1 pixel_cnt;
                current_row_y <= #0.1 current_row_y;
                y_bias <= #0.1 y_bias;
            end
            else begin
                data_valid <= #0.1 data_valid;
                x_delta <= #0.1 x_delta;
                y_delta <= #0.1 y_delta;
                current_row_y <= #0.1 current_row_y;
                pixel_cnt <= #0.1 pixel_cnt;
                y_bias <= #0.1 y_bias;
                pre_bias <= #0.1 pre_bias;
                next_bias_mul_r <= #0.1 next_bias_mul_r;
            end
        end
    end
    
    // 轴计算完成信号
    reg axis_done_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axis_done_r <= #0.1 1'b0;
        end
        else if (axis_cal_status) begin
            axis_done_r <= #0.1 1'b1;
        end
        else begin
            axis_done_r <= #0.1 1'b0;
        end
    end

    assign axis_done = axis_done_r;

endmodule
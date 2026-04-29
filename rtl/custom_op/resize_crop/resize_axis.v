module resize_axis (
    // 来自FSM的控制信号
    input               axis_pre_cal,       // 预计算信号,计算裁剪区域和缩放比例
    input               axis_cal_status,    // 轴计算状态激活 (来自resize_fsm)
    input               resize_status,      // Resize操作状态激活 (来自resize_fsm)
    input       [1:0]  trans_status,       // 传输状态 (来自resize_fsm)

    // 来自寄存器的图像尺寸
    input       [15:0] rwidth_rs,          // 读宽度
    input       [15:0] rheight_rs,          // 读高度
    input       [15:0] wwidth_rs,           // 写宽度
    input       [15:0] wheight_rs,          // 写高度

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

    // ============ 取倒数模块 ============
    // 计算两种ratio:
    // 1. ratio_less = wsize / rsize (小于1): 用于坐标计算
    // 2. ratio_greater = rsize / wsize (大于1): 用于有效数据量计算
    // 所有ratio均使用Q1.3.12格式(16bit: 1符号+3整数+12小数)
    wire [15:0] reciprocal_rwidth;    // 1/rwidth_rs, Q1.3.12
    wire [15:0] reciprocal_rheight;   // 1/rheight_rs, Q1.3.12
    wire [15:0] reciprocal_wwidth;    // 1/wwidth_rs, Q1.3.12
    wire [15:0] reciprocal_wheight;   // 1/wheight_rs, Q1.3.12
    wire        reciprocal_rwidth_valid;
    wire        reciprocal_rheight_valid;
    wire        reciprocal_wwidth_valid;
    wire        reciprocal_wheight_valid;

    // 计算 1/rwidth_rs
    reciprocal #(
        .DATA_WIDTH(16),
        .FRAC_WIDTH(12),  // Q1.3.12格式
        .ITER_NUM(3)
    ) u_reciprocal_rwidth (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (axis_pre_cal),
        .dividend   (rwidth_rs),
        .valid_out  (reciprocal_rwidth_valid),
        .reciprocal (reciprocal_rwidth),
        .ready      ()
    );

    // 计算 1/rheight_rs
    reciprocal #(
        .DATA_WIDTH(16),
        .FRAC_WIDTH(12),  // Q1.3.12格式
        .ITER_NUM(3)
    ) u_reciprocal_rheight (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (axis_pre_cal),
        .dividend   (rheight_rs),
        .valid_out  (reciprocal_rheight_valid),
        .reciprocal (reciprocal_rheight),
        .ready      ()
    );

    // 计算 1/wwidth_rs
    reciprocal #(
        .DATA_WIDTH(16),
        .FRAC_WIDTH(12),  // Q1.3.12格式
        .ITER_NUM(3)
    ) u_reciprocal_wwidth (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (axis_pre_cal),
        .dividend   (wwidth_rs),
        .valid_out  (reciprocal_wwidth_valid),
        .reciprocal (reciprocal_wwidth),
        .ready      ()
    );

    // 计算 1/wheight_rs
    reciprocal #(
        .DATA_WIDTH(16),
        .FRAC_WIDTH(12),  // Q1.3.12格式
        .ITER_NUM(3)
    ) u_reciprocal_wheight (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (axis_pre_cal),
        .dividend   (wheight_rs),
        .valid_out  (reciprocal_wheight_valid),
        .reciprocal (reciprocal_wheight),
        .ready      ()
    );

    // ============ 预计算阶段 (axis_pre_cal) ============
    // 计算两种缩放比例,并存入寄存器
    // ratio_less = wsize / rsize (小于1): 用于坐标计算, Q1.3.12格式
    // ratio_greater = rsize / wsize (大于1): 用于有效数据量计算, Q1.7.8格式

    reg [15:0] width_ratio_less;     // Q1.3.12格式, w/r < 1
    reg [15:0] height_ratio_less;   // Q1.3.12格式, h/r < 1
    reg [15:0] width_ratio_greater; // Q1.7.8格式, r/w > 1
    reg [15:0] height_ratio_greater;// Q1.3.12格式, r/h > 1
    reg        axis_pre_cal_done_r;

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
            if (reciprocal_rwidth_valid && reciprocal_rheight_valid &&
                reciprocal_wwidth_valid && reciprocal_wheight_valid) begin
                // ratio_less = wsize / rsize (小于1), Q1.3.12格式
                // reciprocal_rwidth(16.12) × wwidth_rs(16.0<<12) = 32.24 → >>12 → 16.12
                width_ratio_less <= #0.1 (reciprocal_rwidth * {1'b0, wwidth_rs[15:0], 12'b0}) >> 12;
                height_ratio_less <= #0.1 (reciprocal_rheight * {1'b0, wheight_rs[15:0], 12'b0}) >> 12;
                // ratio_greater = rsize / wsize (大于1), Q1.7.8格式
                // reciprocal_wwidth(16.12) × rwidth_rs(16.0<<12) = 32.24 → >>8 → 16.8 (Q1.7.8)
                width_ratio_greater <= #0.1 (reciprocal_wwidth * {1'b0, rwidth_rs[15:0], 12'b0}) >> 8;
                height_ratio_greater <= #0.1 (reciprocal_wheight * {1'b0, rheight_rs[15:0], 12'b0}) >> 12;
                axis_pre_cal_done_r <= #0.1 1'b1;
            end
            else begin
                width_ratio_less <= #0.1 width_ratio_less;
                height_ratio_less <= #0.1 height_ratio_less;
                width_ratio_greater <= #0.1 width_ratio_greater;
                height_ratio_greater <= #0.1 height_ratio_greater;
                axis_pre_cal_done_r <= #0.1 height_ratio_greater;
            end
        end
        else begin
            width_ratio_less <= #0.1 width_ratio_less;
            height_ratio_less <= #0.1 height_ratio_less;
            width_ratio_greater <= #0.1 width_ratio_greater;
            height_ratio_greater <= #0.1 height_ratio_greater;
            axis_pre_cal_done_r <= #0.1 axis_pre_cal;
        end
    end

    assign axis_pre_cal_done = axis_pre_cal_done_r;

    // ============ 轴计算阶段 (axis_cal_status) ============
    // 两级流水线设计:
    // 第一级: 计算width_ratio_greater*i, y_delta, y_bias, next_bias的乘法
    // 第二级: 计算width_ratio_greater*i - pre_bias

    // 当前行y坐标寄存器
    reg     [15:0] current_row_y;   // INT16格式

    // 当前行像素计数器
    reg     [15:0] pixel_cnt;
    reg     [15:0] pre_bias;        // Q1.7.8格式
    wire    [31:0] ratioed_x_full;  // Q2.10.20格式
    wire    [31:0] ratioed_x_full_add;
    wire    [15:0] ratioed_x;       // Q1.7.8格式
    wire    [31:0] ratioed_y_full;
    wire    [15:0] pixel_cnt_next;

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

    // ============ 第一级计算 ============
    // (16 + pre_bias): Q1.7.8格式
    assign ratioed_x_full_add = ({1'b0, 7'd16, 8'd0} + pre_bias);
    //Q1.23.8格式
    assign ratioed_y_full = height_ratio_greater * current_row_y; 
    assign pixel_cnt_next = pixel_cnt + 16;

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

    // 第一级: y_delta, y_bias, current_row_y, next_bias乘法
    assign y_delta_next = (pixel_cnt == 16'b0) ? ratioed_y_full_r[11:4] : y_delta;
    assign y_bias_next = (pixel_cnt == 16'b0) ? ratioed_y_full_r[27:12] : y_bias;
    assign current_row_y_next = (pixel_cnt == 16'b0) ? current_row_y + 1 : current_row_y;

    // ============ 第二级计算 ============
    // 第二级: 使用第一级锁存结果计算 width_ratio_greater * i - pre_bias
    assign x_delta_sub[15:0]   = x_delta_mul_r[15:0]   - pre_bias;
    assign x_delta_sub[31:16]  = x_delta_mul_r[31:16]  - pre_bias;
    assign x_delta_sub[47:32]  = x_delta_mul_r[47:32]  - pre_bias;
    assign x_delta_sub[63:48]  = x_delta_mul_r[63:48]  - pre_bias;
    assign x_delta_sub[79:64]  = x_delta_mul_r[79:64]  - pre_bias;
    assign x_delta_sub[95:80]  = x_delta_mul_r[95:80]  - pre_bias;
    assign x_delta_sub[111:96] = x_delta_mul_r[111:96] - pre_bias;
    assign x_delta_sub[127:112]= x_delta_mul_r[127:112]- pre_bias;
    assign x_delta_sub[143:128]= x_delta_mul_r[143:128]- pre_bias;
    assign x_delta_sub[159:144]= x_delta_mul_r[159:144]- pre_bias;
    assign x_delta_sub[175:160]= x_delta_mul_r[175:160]- pre_bias;
    assign x_delta_sub[191:176]= x_delta_mul_r[191:176]- pre_bias;
    assign x_delta_sub[207:192]= x_delta_mul_r[207:192]- pre_bias;
    assign x_delta_sub[223:208]= x_delta_mul_r[223:208]- pre_bias;
    assign x_delta_sub[239:224]= x_delta_mul_r[239:224]- pre_bias;
    assign x_delta_sub[255:240]= x_delta_mul_r[255:240]- pre_bias;

    // next_bias 乘法: width_ratio_greater * ratioed_x[15:8]
    assign next_bias_mul = width_ratio_greater * ratioed_x[15:8];
    // pre_bias_next = 16 - next_bias_mul (使用第一级锁存结果)
    assign pre_bias_next = (pixel_cnt_next_r == rwidth_rs) ?
                           16'b0 :
                           {1'b0, 7'd16, 8'd0} - (next_bias_mul_r);

    assign ratioed_x_full = width_ratio_less * ratioed_x_full_add_r;
    assign ratioed_x = ratioed_x_full[27:12];  // 提取16bit (8整数+8小数)

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
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            axis_cal_status_reg <= #0.1 1'b0;
        end
        else begin
            axis_cal_status_reg <= #0.1 axis_cal_status;
        end
    end
    assign axis_cal_negedge = ~axis_cal_status & axis_cal_status_reg;  // 下降沿检测

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            data_valid <= #0.1 8'd0;
            x_delta <= #0.1 256'd0;
            y_delta <= #0.1 8'd0;
            pixel_cnt <= #0.1 16'd0;
            current_row_y <= #0.1 16'd0;
            y_bias <= #0.1 16'd0;
            next_bias_mul_r <= #0.1 16'd0;
            pre_bias <= #0.1 16'd0;
        end
        else begin
            if(axis_cal_status) begin
                // 第二级结果锁存到输出
                data_valid <= ratioed_x[15:8];
                x_delta <= #0.1 x_delta_sub;
                y_delta <= #0.1 y_delta_next_r;
                y_bias <= #0.1 y_bias_next_r;
                current_row_y <= #0.1 current_row_y_next_r;
                pixel_cnt <= #0.1 (pixel_cnt_next_r == rwidth_rs) ? 16'b0 : pixel_cnt_next_r;
                next_bias_mul_r <= #0.1 next_bias_mul[15:0]; //第二级更新
                pre_bias <= #0.1 pre_bias;
            end
            else if(axis_cal_negedge) begin
                // axis_cal_status 下降沿: 更新 pre_bias
                next_bias_mul_r <= #0.1 next_bias_mul_r;
                pre_bias <= #0.1 pre_bias_next;
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
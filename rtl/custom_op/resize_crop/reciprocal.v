//================================================================================
// Orgnization   : School of Electronic Science, NUDT
// File Name     : reciprocal.v
// Author        : Changtai Lin
// Project       :
// Create Date   : 2026.04.27
// Description   : 定点数求倒数模块
//                 使用牛顿-拉夫森迭代法求解 1/x
//--------------------------------------------------------------------------------
// Modification History :
//================================================================================
//
// 算法原理：牛顿-拉夫森迭代法
// ------------------
// 对于求 1/x，构造方程 f(y) = 1/y - x = 0
// 对 f(y) 在 y_n 处进行泰勒展开并求解得迭代公式：
//     y_{n+1} = y_n × (2 - x × y_n)
// 此公式具有二阶收敛特性，每次迭代精度约翻倍
//
// 定点数格式：
// ------------------
// DATA_WIDTH = 16bit，FRAC_WIDTH = 14bit（小数位）
// 格式：[符号位|整数位|小数位] = [1bit|1bit|14bit]
// 范围：无符号 [0, 2)，有符号 [-1, 1)
// 注意：被求倒数的输入应为 [0.5, 2) 范围内的定点数
//
// 计算流程：
// ------------------
// INIT 状态：y_0 = 2 - x（初始估计，在[1,2)范围时近似1/x）
// ITER 1  ：y_1 = y_0 × (2 - x × y_0)
// ITER 2  ：y_2 = y_1 × (2 - x × y_1)
// ITER 3  ：y_3 = y_2 × (2 - x × y_2) → 即为最终结果
//
//================================================================================

module reciprocal #(
    parameter DATA_WIDTH = 16,      // 输入数据位宽
    parameter FRAC_WIDTH = 14,      // 小数位宽
    parameter ITER_NUM = 3           // 迭代次数
)(
    input                           clk,
    input                           rst_n,

    input                           valid_in,    // 输入有效
    input       [DATA_WIDTH-1:0]    dividend,    // 被除数 (x)，即要计算1/x的数
    output reg                      valid_out,   // 输出有效
    output reg      [DATA_WIDTH-1:0] reciprocal, // 1/x 的定点数表示
    output reg                      ready        // 模块就绪
);

    // 牛顿-拉夫森迭代状态机
    // ---------------------------------------------------
    // IDLE  : 等待输入，当 valid_in 且 dividend != 0 时进入 INIT
    // INIT  : 初始化迭代，将 x_n = dividend，y_n = 2 - x（初始估计）
    // ITER  : 执行牛顿-拉夫森迭代 y_{n+1} = y_n × (2 - x × y_n)
    // DONE  : 迭代完成，输出结果 reciprocal = y_n
    localparam IDLE = 2'd0;
    localparam INIT = 2'd1;
    localparam ITER = 2'd2;
    localparam DONE = 2'd3;

    // 状态机寄存器
    reg [1:0] state;
    reg [1:0] next_state;

    // 迭代过程寄存器
    reg [DATA_WIDTH-1:0] x_n;        // 当前迭代的被除数（保持不变）
    reg [DATA_WIDTH-1:0] y_n;        // 当前迭代的1/x近似值
    reg [2:0] iter_cnt;             // 迭代计数器

    // 初始估计值计算
    // ---------------------------------------------------
    // 原理：对于 x ∈ [1, 2)，有 1/x ∈ (0.5, 1]
    // 初始估计 y_init = 2 - x，则：
    //   当 x=1.0 时，y_init=1.0（精确）
    //   当 x=1.5 时，y_init=0.5（近似）
    //   当 x=2.0 时，y_init=0.0（近似）
    // 实现：y_init = 2 - dividend = {1'b1, ~dividend[DATA_WIDTH-2:0]} + 1
    //   其中 {1'b1, ...} 表示常数2（定点数格式）
    wire [DATA_WIDTH-1:0] y_init;
    assign y_init = {1'b1, ~dividend[DATA_WIDTH-2:0]} + 1'b1;

    // 状态转移（时序逻辑）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end
        else begin
            state <= next_state;
        end
    end

    // 状态转换条件（组合逻辑）
    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                // 当输入有效且被除数非零时，开始计算
                if (valid_in && dividend != 0) begin
                    next_state = INIT;
                end
            end
            INIT: begin
                // 初始化完成，进入迭代阶段
                next_state = ITER;
            end
            ITER: begin
                // 达到指定迭代次数后，进入完成状态
                if (iter_cnt == ITER_NUM - 1) begin
                    next_state = DONE;
                end
            end
            DONE: begin
                // 完成一次计算后，返回空闲状态等待下一个输入
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    // 迭代计算（时序逻辑）
    // ---------------------------------------------------
    // 牛顿-拉夫森迭代公式：y_{n+1} = y_n × (2 - x_n × y_n)
    // 展开步骤：
    //   Step 1: mul_temp  = x_n × y_n
    //   Step 2: two_xy    = 2 - mul_temp[DATA_WIDTH-1:0]
    //   Step 3: mul_temp2 = y_n × two_xy
    //   Step 4: y_n       = mul_temp2[DATA_WIDTH-1:0]
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_n <= 0;
            y_n <= 0;
            iter_cnt <= 0;
            valid_out <= 0;
            ready <= 1;
        end
        else begin
            case (state)
                IDLE: begin
                    // 空闲状态，初始化所有信号
                    valid_out <= 0;
                    ready <= 1;
                    iter_cnt <= 0;
                end

                INIT: begin
                    // 初始化阶段：设置被求倒数的值和初始估计
                    ready <= 0;                 // 模块忙
                    x_n <= dividend;           // x_n = x（被除数）
                    y_n <= y_init;              // y_n = 2 - x（初始估计）
                    iter_cnt <= 0;
                end

                ITER: begin
                    // ----------------------------------------
                    // 第一步：计算 x_n × y_n
                    // ----------------------------------------
                    reg [DATA_WIDTH*2-1:0] mul_temp;
                    mul_temp = x_n * y_n;

                    // ----------------------------------------
                    // 第二步：计算 2 - x_n × y_n
                    // 常数2的定点数表示：{1'b1, {(DATA_WIDTH-1){1'b0}}}
                    // 即 2.0 = binary 10.00000000000000
                    // ----------------------------------------
                    reg [DATA_WIDTH-1:0] two_minus_xy;
                    two_minus_xy = {1'b1, {(DATA_WIDTH-1){1'b0}}} - mul_temp[DATA_WIDTH-1:0];

                    // ----------------------------------------
                    // 第三步：计算 y_n × (2 - x_n × y_n)
                    // ----------------------------------------
                    reg [DATA_WIDTH*2-1:0] mul_temp2;
                    mul_temp2 = y_n * two_minus_xy;

                    // ----------------------------------------
                    // 第四步：更新 y_n，进入下一次迭代
                    // ----------------------------------------
                    y_n <= mul_temp2[DATA_WIDTH-1:0];
                    iter_cnt <= iter_cnt + 1'b1;
                end

                DONE: begin
                    // 迭代完成，输出结果
                    reciprocal <= y_n;
                    valid_out <= 1;
                    ready <= 1;
                end
            endcase
        end
    end

endmodule
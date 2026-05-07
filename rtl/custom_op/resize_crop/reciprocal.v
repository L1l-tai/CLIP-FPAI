//================================================================================
// File Name     : reciprocal.v
// Project       :
// Create Date   : 2026.04.27
// Description   : 定点数求倒数模块
//                 使用牛顿-拉夫森迭代法求解 1/x
//--------------------------------------------------------------------------------
// Modification History :
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

    // 牛顿-拉夫森迭代状态机（三级流水线）
    // ---------------------------------------------------
    // IDLE   : 等待输入，当 valid_in 且 dividend != 0 时进入 INIT
    // INIT   : 初始化迭代，将 x_n = dividend，y_n = 2 - x（初始估计）
    // ITER1  : 第一级流水线 - 计算 mul_temp = x_n × y_n
    // ITER2  : 第二级流水线 - 计算 two_minus_xy = 2 - mul_temp
    // ITER3  : 第三级流水线 - 计算 mul_temp2 = y_n × two_minus_xy，更新 y_n 和 iter_cnt
    // DONE   : 迭代完成，输出结果 reciprocal = y_n
    localparam IDLE  = 4'd0;
    localparam INIT  = 4'd1;
    localparam ITER1 = 4'd2;
    localparam ITER2 = 4'd3;
    localparam ITER3 = 4'd4;
    localparam DONE  = 4'd5;

    // 状态机寄存器
    reg [2:0] state;
    reg [2:0] next_state;

    // 迭代过程寄存器
    reg [DATA_WIDTH-1:0] x_n;        // 当前迭代的被除数（保持不变）
    reg [DATA_WIDTH-1:0] y_n;        // 当前迭代的1/x近似值
    reg [2:0] iter_cnt;             // 迭代计数器

    // 三级流水线寄存器
    reg [DATA_WIDTH*2-1:0] mul_temp_r;      // 第一级流水线寄存器
    reg [DATA_WIDTH-1:0] two_minus_xy_r;    // 第二级流水线寄存器
    reg [DATA_WIDTH*2-1:0] mul_temp2_r;      // 第三级流水线寄存器

    // 迭代计算中间信号（组合逻辑）
    wire [DATA_WIDTH*2-1:0] mul_temp;    // x_n × y_n
    wire [DATA_WIDTH-1:0] two_minus_xy;   // 2 - x_n × y_n
    wire [DATA_WIDTH*2-1:0] mul_temp2;    // y_n × two_minus_xy

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

    // 迭代计算组合逻辑赋值（三级流水线）
    // ---------------------------------------------------
    // 第一级：mul_temp = x_n × y_n
    assign mul_temp = x_n * y_n;

    // 第二级：two_minus_xy = 2 - mul_temp
    assign two_minus_xy = {1'b1, {(DATA_WIDTH-1){1'b0}}} - mul_temp_r[DATA_WIDTH-1:0];

    // 第三级：mul_temp2 = y_n × two_minus_xy
    assign mul_temp2 = y_n * two_minus_xy_r;

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
                if (valid_in && dividend != 0) begin
                    next_state = INIT;
                end
            end
            INIT: begin
                next_state = ITER1;
            end
            ITER1: begin
                next_state = ITER2;
            end
            ITER2: begin
                next_state = ITER3;
            end
            ITER3: begin
                if (iter_cnt == ITER_NUM) begin
                    next_state = DONE;
                end
                else begin
                    next_state = ITER1;
                end
            end
            DONE: begin
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    // 迭代计算（三级流水线时序逻辑）
    // ---------------------------------------------------
    // 牛顿-拉夫森迭代公式：y_{n+1} = y_n × (2 - x_n × y_n)
    // 三级流水线：
    //   第一级 (ITER1)：mul_temp_r <= x_n × y_n
    //   第二级 (ITER2)：two_minus_xy_r <= 2 - mul_temp_r
    //   第三级 (ITER3)：mul_temp2_r <= y_n × two_minus_xy_r
    //                  y_n <= mul_temp2_r[DATA_WIDTH-1:0]
    //                  iter_cnt++
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_n <= 0;
            y_n <= 0;
            iter_cnt <= 0;
            valid_out <= 0;
            ready <= 1;
            mul_temp_r <= 0;
            two_minus_xy_r <= 0;
            mul_temp2_r <= 0;
        end
        else begin
            case (state)
                IDLE: begin
                    valid_out <= 0;
                    ready <= 1;
                    iter_cnt <= 0;
                    mul_temp_r <= 0;
                    two_minus_xy_r <= 0;
                    mul_temp2_r <= 0;
                end

                INIT: begin
                    ready <= 0;
                    x_n <= dividend;
                    y_n <= y_init;
                    iter_cnt <= 0;
                    mul_temp_r <= 0;
                    two_minus_xy_r <= 0;
                    mul_temp2_r <= 0;
                end

                ITER1: begin
                    // 第一级：计算 mul_temp = x_n × y_n
                    mul_temp_r <= mul_temp;
                    two_minus_xy_r <= two_minus_xy_r;
                    mul_temp2_r <= mul_temp2_r;
                end

                ITER2: begin
                    // 第二级：计算 two_minus_xy = 2 - mul_temp
                    mul_temp_r <= mul_temp_r;
                    two_minus_xy_r <= two_minus_xy;
                    mul_temp2_r <= mul_temp2_r;
                end

                ITER3: begin
                    // 第三级：计算 mul_temp2 = y_n × two_minus_xy，完成一次迭代
                    mul_temp_r <= mul_temp_r;
                    two_minus_xy_r <= two_minus_xy_r;
                    mul_temp2_r <= mul_temp2;
                    y_n <= mul_temp2[DATA_WIDTH-1:0];
                    iter_cnt <= iter_cnt + 1'b1;
                end

                DONE: begin
                    reciprocal <= y_n;
                    valid_out <= 1;
                    ready <= 1;
                end
            endcase
        end
    end

endmodule
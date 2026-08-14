module fwht_pub #(
    parameter EXP_W = 5,        // FP16指数宽度
    parameter MAN_W = 13,       // 内部计算位宽 (FP16/INT16共享, 13bit覆盖FWHT最大幅值8128)
    parameter FP_W  = 16,       // 数据总线宽度
    parameter INT8_W = 8        // INT8位宽 (输入/输出截断参考)
)(
    input  wire             clk,
    input  wire             rst_n,

    // 输入: FP16格式或INT16格式(INT8符号扩展到bit15), 统一16-bit
    input  wire [FP_W-1:0]  op_a,
    input  wire [FP_W-1:0]  op_b,
    input  wire             cal_percision, // 1=FP16, 0=INT16
    input  wire             valid_in,

    // 输出
    output reg  [FP_W-1:0]  result_add, // A+B
    output reg  [FP_W-1:0]  result_sub, // A-B
    output reg              valid_out
);

    // FP16标准尾数位宽 (用于FP16路径的bit切片, 不参与信号宽度声明)
    localparam FP16_MW = 10;

    // --- 公共信号 (宽度由MAN_W=13决定) ---
    wire                sign_a;
    wire                sign_b;
    wire [EXP_W-1:0]    exp_a;
    wire [EXP_W-1:0]    exp_b;
    wire [MAN_W:0]      man_a;       // 14-bit (MAN_W+1), FP16/INT16共享
    wire [MAN_W:0]      man_b;

    // --- Stage 1: Shared Pre-alignment ---
    reg               s1_sign_a, s1_sign_b;
    reg [EXP_W-1:0]   s1_exp_diff;
    reg [EXP_W:0]     s1_exp_max;
    reg [MAN_W+1:0]   s1_man_big;          // 15-bit, 含guard bit
    reg [MAN_W+5:0]   s1_man_small_shifted; // 19-bit, 对齐后的小数尾数
    reg               s1_a_ge_b;
    reg               s1_valid;

    // --- Stage 2: ADD/SUB 运算 ---
    reg [MAN_W+2:0]   s2_sum_add;    // 16-bit, 加法结果
    reg [EXP_W:0]     s2_exp_add;
    reg               s2_sign_add;

    reg [MAN_W+1:0]   s2_diff_sub;   // 15-bit, 减法结果
    reg [EXP_W:0]     s2_exp_sub;
    reg               s2_sign_sub;
    reg               s2_valid;

    // --- 流水线化的符号 (随数据一起传递) ---
    reg s1_sign_a_r, s1_sign_b_r;
    reg s2_sign_a_r, s2_sign_b_r;
    reg s3_sign_a_r, s3_sign_b_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_sign_a_r <= 1'b0; s1_sign_b_r <= 1'b0;
            s2_sign_a_r <= 1'b0; s2_sign_b_r <= 1'b0;
            s3_sign_a_r <= 1'b0; s3_sign_b_r <= 1'b0;
        end else begin
            s1_sign_a_r <= sign_a; s1_sign_b_r <= sign_b;
            s2_sign_a_r <= s1_sign_a_r; s2_sign_b_r <= s1_sign_b_r;
            s3_sign_a_r <= s2_sign_a_r; s3_sign_b_r <= s2_sign_b_r;
        end
    end

    // --- Stage 3: Normalization (仅FP16使用, INT16跳过) ---
    reg [MAN_W:0]     s3_man_add_norm;
    reg [EXP_W:0]     s3_exp_add_norm;
    reg               s3_sign_add_norm;

    reg [MAN_W:0]     s3_man_sub_norm;
    reg [EXP_W:0]     s3_exp_sub_norm;
    reg               s3_sign_sub_norm;
    reg               s3_valid;

    // --- 组合逻辑辅助信号 ---
    wire [EXP_W:0]  exp_diff_s;
    wire [EXP_W:0]  exp_diff_abs;
    wire            a_ge_b;
    wire [MAN_W+1:0] man_big;
    wire [MAN_W+1:0] man_small;
    wire [MAN_W-1:0] man_a_int16_abs;  // 13-bit INT16幅值
    wire [MAN_W-1:0] man_b_int16_abs;

    // =========================================================================
    // Stage 0: 参数提取
    //   FP16: sign=bit15, exp=bit[14:10], man=bit[9:0]+implicit1
    //   INT16: sign=bit15, exp恒为0, man=取bit[14:0]绝对值后截断到13-bit
    // =========================================================================

    // 符号位: FP16/INT16 均在 bit 15
    assign sign_a = op_a[FP_W-1];
    assign sign_b = op_b[FP_W-1];

    // 指数: FP16 在 bit[14:10] (FP16_MW +: EXP_W)
    //       INT16 恒为0 (高8位是符号扩展, 非指数, 不归零会破坏对齐)
    assign exp_a  = cal_percision ? op_a[FP16_MW +: EXP_W] : 5'd0;
    assign exp_b  = cal_percision ? op_b[FP16_MW +: EXP_W] : 5'd0;

    // INT16: 15-bit有符号 → 绝对值 → 截断到 MAN_W (13-bit)
    // FP16 时门控为常数 0, 常量传播优化掉加法器
    wire [14:0] int16_abs_a_val;
    wire [14:0] int16_abs_b_val;
    wire [14:0] int16_abs_a;
    wire [14:0] int16_abs_b;
    assign int16_abs_a_val = sign_a ? (~op_a[14:0] + 1'b1) : op_a[14:0];
    assign int16_abs_b_val = sign_b ? (~op_b[14:0] + 1'b1) : op_b[14:0];
    assign int16_abs_a = cal_percision ? 15'd0 : int16_abs_a_val;
    assign int16_abs_b = cal_percision ? 15'd0 : int16_abs_b_val;
    assign man_a_int16_abs = int16_abs_a[MAN_W-1:0];
    assign man_b_int16_abs = int16_abs_b[MAN_W-1:0];

    // man: FP16=implicit1+10bit尾数(低位对齐), INT16=13bit幅值(低位对齐)
    //      两者打包进 MAN_W+1=14-bit 容器, 高位填0
    // 修复: subnormal (exp==0) flush-to-zero —— subnormal 真实指数为 -14,
    //   硬件按 exp=0 参与对齐会错 14 位, 特定数据组合下产生错误输出 (±640 级)。
    //   subnormal 值 ~1e-5, FTZ 对 FWHT 结果影响可忽略。
    assign man_a = cal_percision
        ? ((exp_a != 0) ? { {(MAN_W-FP16_MW){1'b0}}, 1'b1, op_a[FP16_MW-1:0] }
                        : {(MAN_W+1){1'b0}})
        : {1'b0, man_a_int16_abs};

    assign man_b = cal_percision
        ? ((exp_b != 0) ? { {(MAN_W-FP16_MW){1'b0}}, 1'b1, op_b[FP16_MW-1:0] }
                        : {(MAN_W+1){1'b0}})
        : {1'b0, man_b_int16_abs};

    // =========================================================================
    // Stage 1: Shared Pre-alignment (共享预对齐)
    //   INT16 路径: exp_a==exp_b==0, exp_diff_abs=0, 不移位
    // =========================================================================

    assign exp_diff_s   = {1'b0, exp_a} - {1'b0, exp_b};
    assign exp_diff_abs = exp_diff_s[EXP_W] ? -exp_diff_s : exp_diff_s;
    assign a_ge_b = (exp_a > exp_b) || (exp_a == exp_b && man_a >= man_b);
    assign man_big = a_ge_b ? man_a : man_b;
    assign man_small = a_ge_b ? man_b : man_a;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid      <= valid_in;
            s1_sign_a     <= sign_a;
            s1_sign_b     <= sign_b;
            s1_a_ge_b     <= a_ge_b;
            s1_exp_diff   <= exp_diff_s[EXP_W:0];
            s1_exp_max    <= a_ge_b ? {1'b0, exp_a} : {1'b0, exp_b};
            s1_man_big    <= {man_big, 1'b0};
            s1_man_small_shifted <= {man_small, 1'b0} >> exp_diff_abs;
        end
    end

    // =========================================================================
    // Stage 2: ADD/SUB 运算
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid    <= s1_valid;
            s2_sum_add  <= {1'b0, s1_man_big} + {1'b0, s1_man_small_shifted};
            s2_exp_add  <= s1_exp_max;
            s2_sign_add <= s1_sign_a;
            s2_diff_sub <= s1_man_big - s1_man_small_shifted;
            s2_sign_sub <= s1_a_ge_b ? s1_sign_a : ~s1_sign_a;
            s2_exp_sub  <= s1_exp_max;
        end
    end

    // =========================================================================
    // Stage 3: Normalization (仅FP16使用, INT16路径 valid_out=s2_valid 跳过)
    // =========================================================================

    // Two-stage Priority Encoder: 检测 s2_diff_sub[11:0] 前导1位置
    // INT16 时输入门控为 0, 常量传播优化掉 LOD 逻辑
    wire [MAN_W+1:0] s2_diff_sub_norm;
    wire [2:0] group_msb_5;
    assign s2_diff_sub_norm = cal_percision ? s2_diff_sub : 0;
    wire [2:0] group_msb_0;
    wire       msb_in_upper;
    wire [3:0] sub_leading_pos;

    assign group_msb_5 =
        (s2_diff_sub_norm[11]) ? 3'd5 :
        (s2_diff_sub_norm[10]) ? 3'd4 :
        (s2_diff_sub_norm[9])  ? 3'd3 :
        (s2_diff_sub_norm[8])  ? 3'd2 :
        (s2_diff_sub_norm[7])  ? 3'd1 :
        (s2_diff_sub_norm[6])  ? 3'd0 : 3'd6;

    assign group_msb_0 =
        (s2_diff_sub_norm[5])  ? 3'd5 :
        (s2_diff_sub_norm[4])  ? 3'd4 :
        (s2_diff_sub_norm[3])  ? 3'd3 :
        (s2_diff_sub_norm[2])  ? 3'd2 :
        (s2_diff_sub_norm[1])  ? 3'd1 :
                         3'd0;  // bit[0] → pos 0, 无bit → 0 (由 s2_diff_sub==0 单独处理)

    assign msb_in_upper = (group_msb_5 != 3'd6);
    assign sub_leading_pos = msb_in_upper ? (group_msb_5 + 3'd6) : group_msb_0;

    // =========================================================================
    // ADD 归一化: 优先编码检测前导 1, 右移到 FP16_MW 位置
    //   s2_sum_add[MAN_W+1:1] 是去 guard 后的 14-bit 尾数
    //   FP16 输出期望隐式 1 在 bit[10], 若前导 1 在更高位则需右移
    // =========================================================================
    // INT16 时门控: add_needs_shift=0, add_shift_amt=0
    wire [1:0] add_shift_amt;
    wire       add_needs_shift;
    assign add_needs_shift = cal_percision && |s2_sum_add[MAN_W+1:FP16_MW+2];
    assign add_shift_amt   = cal_percision ?
                             (s2_sum_add[MAN_W+1] ? 2'd3 :
                              s2_sum_add[MAN_W  ] ? 2'd2 :
                              s2_sum_add[FP16_MW+2] ? 2'd1 : 2'd0) : 2'd0;

    // 归一化移位: 用 FP16_MW 对准 FP16 尾数位宽
    wire [MAN_W+1:0] sub_shifted;
    assign sub_shifted = s2_diff_sub << (FP16_MW + 1 - sub_leading_pos);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid          <= 1'b0;
            s3_man_add_norm   <= {(MAN_W+1){1'b0}};
            s3_exp_add_norm   <= {(EXP_W+1){1'b0}};
            s3_sign_add_norm  <= 1'b0;
            s3_man_sub_norm   <= {(MAN_W+1){1'b0}};
            s3_exp_sub_norm   <= {(EXP_W+1){1'b0}};
            s3_sign_sub_norm  <= 1'b0;
        end else if (cal_percision) begin
            // FP16: 完整归一化逻辑
            s3_valid <= s2_valid;

            // ADD Path: 前导 1 检测 + 可变右移 (对齐到 FP16_MW=10)
            if (add_needs_shift) begin
                s3_man_add_norm <= s2_sum_add[MAN_W+1:1] >> add_shift_amt;
                s3_exp_add_norm <= s2_exp_add + {1'b0, add_shift_amt};
            end else begin
                s3_man_add_norm <= s2_sum_add[MAN_W+1:1];
                s3_exp_add_norm <= s2_exp_add;
            end
            s3_sign_add_norm <= s2_sign_add;

            // SUB Path: 前导1检测 + 可变左移
            if (s2_diff_sub == 0) begin
                s3_man_sub_norm  <= {(MAN_W+1){1'b0}};
                s3_exp_sub_norm  <= {(EXP_W+1){1'b0}};
                s3_sign_sub_norm <= 1'b0;
            end else begin
                s3_man_sub_norm  <= sub_shifted[MAN_W+1:1];
                s3_exp_sub_norm  <= s2_exp_sub - (FP16_MW + 1 - sub_leading_pos);
                s3_sign_sub_norm <= s2_sign_sub;
            end
        end else begin
            // INT16: 寄存器恒为 0, 综合工具常量传播优化
            s3_valid          <= s2_valid;
            s3_man_add_norm   <= {(MAN_W+1){1'b0}};
            s3_exp_add_norm   <= {(EXP_W+1){1'b0}};
            s3_sign_add_norm  <= 1'b0;
            s3_man_sub_norm   <= {(MAN_W+1){1'b0}};
            s3_exp_sub_norm   <= {(EXP_W+1){1'b0}};
            s3_sign_sub_norm  <= 1'b0;
        end
    end

    // =========================================================================
    // 输出合并
    // =========================================================================

    // FP16 merge: 取 FP16_MW=10 位尾数
    wire [FP_W-1:0] fp16_merge_add;
    wire [FP_W-1:0] fp16_merge_sub;
    assign fp16_merge_add = {s3_sign_add_norm, s3_exp_add_norm[EXP_W-1:0], s3_man_add_norm[FP16_MW-1:0]};
    assign fp16_merge_sub = {s3_sign_sub_norm, s3_exp_sub_norm[EXP_W-1:0], s3_man_sub_norm[FP16_MW-1:0]};

    // INT16 merge: 从宽幅值重建 16-bit 2补码
    //   ADD: s2_sum_add[MAN_W+1:1] = 14-bit 幅值 → {2'b0, 14-bit} → 符号决定2补码
    //   SUB: s2_diff_sub[MAN_W:1]   = 13-bit 幅值 → {3'b0, 13-bit} → 符号决定2补码
    // INT16 merge: 门控, cal_percision=1 时综合器优化掉
    wire [15:0] int16_add_2s;
    wire [15:0] int16_sub_2s;
    wire [15:0] int16_add_pos = cal_percision ? 16'd0 : {2'b0, s2_sum_add[MAN_W+1:1]};
    wire [15:0] int16_sub_pos = cal_percision ? 16'd0 : {3'b0, s2_diff_sub[MAN_W:1]};
    assign int16_add_2s = cal_percision ? 16'd0 :
                          (s2_sign_add ? (~int16_add_pos + 16'd1) : int16_add_pos);
    assign int16_sub_2s = cal_percision ? 16'd0 :
                          (s2_sign_sub ? (~int16_sub_pos + 16'd1) : int16_sub_pos);

    wire [FP_W-1:0] s3_merge_add;
    wire [FP_W-1:0] s3_merge_sub;
    assign s3_merge_add = cal_percision ? fp16_merge_add : int16_add_2s;
    assign s3_merge_sub = cal_percision ? fp16_merge_sub :
                          (int16_sub_2s != 16'd0) ? int16_sub_2s : 16'd0;

    // =========================================================================
    // Stage 4: Post Sign Processing + 输出
    //   result_add = A+B: 同号→ADD, 异号→SUB
    //   result_sub = A-B: 同号→SUB, 异号→ADD
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_add <= 0;
            result_sub <= 0;
            valid_out  <= 1'b0;
        end else begin
            valid_out <= cal_percision ? s3_valid : s2_valid;

            // 使用流水线化符号 (随数据对齐), 非组合逻辑 sign_a/sign_b
            if (cal_percision) begin
                result_add <= s3_sign_a_r == s3_sign_b_r ? s3_merge_add : s3_merge_sub;
                result_sub <= s3_sign_a_r == s3_sign_b_r ? s3_merge_sub : s3_merge_add;
            end else begin
                result_add <= s2_sign_a_r == s2_sign_b_r ? s3_merge_add : s3_merge_sub;
                result_sub <= s2_sign_a_r == s2_sign_b_r ? s3_merge_sub : s3_merge_add;
            end
        end
    end

endmodule

module fwht_pub #(
    parameter EXP_W = 5,        // FP16指数宽度
    parameter MAN_W = 10,       // FP16尾数宽度
    parameter FP_W  = 16,       // FP16总宽度
    parameter INT8_W = 8        // INT8位宽
)(
    input  wire             clk,
    input  wire             rst_n,

    // 输入
    input  wire [FP_W-1:0]  op_a,       // FP16 输入A (INT8时使用低8位)
    input  wire [FP_W-1:0]  op_b,       // FP16 输入B (INT8时使用低8位)
    input  wire             cal_percision, // 1=FP16, 0=INT8
    input  wire             valid_in,    // 输入有效信号

    // 输出
    output reg  [FP_W-1:0]  result_add, // A + B (FP16或INT8)
    output reg  [FP_W-1:0]  result_sub, // A - B (FP16或INT8)
    output reg              valid_out   // 输出有效信号
);

    wire                sign_a;
    wire                sign_b;
    wire [EXP_W-1:0]    exp_a;
    wire [EXP_W-1:0]    exp_b;
    // 含隐含1, 11-bit (10+1)
    wire [MAN_W:0]      man_a;
    wire [MAN_W:0]      man_b;

        // --- Stage 1: Shared Pre-alignment ---
    reg         s1_sign_a, s1_sign_b;
    reg [EXP_W-1:0] s1_exp_diff;      // exp_a - exp_b (带符号)
    reg [EXP_W:0]   s1_exp_max;       // max(exp_a, exp_b)
    reg [MAN_W+1:0] s1_man_big;       // 较大数的尾数 (12-bit, 含guard bit)
    reg [MAN_W+5:0] s1_man_small_shifted; // 较小数对齐后的尾数 (16-bit, 最多移10+1位)
    reg             s1_a_ge_b;        // |A| >= |B|
    reg             s1_same_sign;     // A和B符号相同
    reg             s1_valid;


    wire [MAN_W+1:0] man_small_aligned;

    // --- Stage 2: ADD/SUB 运算 ---
    // ADD Path (同号路径: 无符号加法)
    reg [MAN_W+2:0]  s2_sum_add;       // 加法结果 (13-bit, 含carry位)
    reg [EXP_W:0]    s2_exp_add;
    reg               s2_sign_add;

    // SUB Path (异号路径: 无符号减法)
    reg [MAN_W+1:0]  s2_diff_sub;      // 减法结果 (12-bit)
    reg [EXP_W:0]    s2_exp_sub;
    reg               s2_sign_sub;     // 减法结果符号
    reg               s2_valid;

    // --- Stage 3: Normalization ---
    // ADD Path: Simplified Norm (overflow check + 1-bit shift)
    reg [MAN_W:0]    s3_man_add_norm;
    reg [EXP_W:0]    s3_exp_add_norm;
    reg              s3_sign_add_norm;

    // SUB Path: Full Norm (leading-1 detection + variable shift)
    reg [MAN_W:0]    s3_man_sub_norm;
    reg [EXP_W:0]    s3_exp_sub_norm;
    reg              s3_sign_sub_norm;
    reg              s3_valid;

    wire [EXP_W:0]  exp_diff_s;
    wire [EXP_W:0]  exp_diff_abs;
    wire [EXP_W:0]  exp_diff_neg;
    wire            a_ge_b;
    wire [MAN_W+1:0] man_big;
    wire [MAN_W+1:0] man_small;
    wire [INT8_W-2:0] man_a_int8_abs;
    wire [INT8_W-2:0] man_b_int8_abs;

    //参数提取
    assign sign_a = cal_percision ? op_a[FP_W-1] : op_a[INT8_W-1];
    assign sign_b = cal_percision ? op_b[FP_W-1] : op_b[INT8_W-1];
    assign exp_a  = op_a[MAN_W +: EXP_W];
    assign exp_b  = op_b[MAN_W +: EXP_W];

    // 尾数: 添加隐含的1 (对于非零数)
    // INT8: 有符号补码，绝对值 = (sign? ~low7 + 1 : low7)
    assign man_a_int8_abs = sign_a ? (~op_a[INT8_W-2:0] + 1'b1) : op_a[INT8_W-2:0];
    assign man_b_int8_abs = sign_b ? (~op_b[INT8_W-2:0] + 1'b1) : op_b[INT8_W-2:0];
    assign man_a  = cal_percision ? ((exp_a != 0) ? {1'b1, op_a[MAN_W-1:0]} : {1'b0, op_a[MAN_W-1:0]}) : {4'b0, man_a_int8_abs};
    assign man_b  = cal_percision ? ((exp_b != 0) ? {1'b1, op_b[MAN_W-1:0]} : {1'b0, op_b[MAN_W-1:0]}) : {4'b0, man_b_int8_abs};

    // =========================================================================
    // Stage 1: Shared Pre-alignment (共享预对齐)
    // =========================================================================
    // 核心: ADD和SUB共用以下逻辑，节省一半Pre-alignment硬件
    //   1. 指数差计算
    //   2. 尾数移位对齐
    //   3. A>B比较与交换 (Swapping)
    // =========================================================================

    assign exp_diff_s = {1'b0, exp_a} - {1'b0, exp_b};
    assign exp_diff_abs = exp_diff_s[EXP_W] ? -exp_diff_s : exp_diff_s; // |exp_a - exp_b|
    assign exp_diff_neg = ~exp_diff_s + 1'b1;
    assign a_ge_b = cal_percision ? (exp_a > exp_b) || (exp_a == exp_b && man_a >= man_b) : man_a >= man_b;
    assign man_big = a_ge_b ? man_a : man_b;
    assign man_small = a_ge_b ? man_b :man_a;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid    <= valid_in;
            s1_sign_a   <= sign_a;
            s1_sign_b   <= sign_b;
            s1_same_sign <= (sign_a == sign_b);
            s1_a_ge_b   <= a_ge_b;

            // 指数差 (带符号)
            s1_exp_diff <= exp_diff_s[EXP_W:0];

            // 较大指数
            s1_exp_max  <= a_ge_b ? {1'b0, exp_a} : {1'b0, exp_b};

            // 交换: 大数在前, 小数移位对齐
            // 大数尾数 (直接使用, 无需移位)
            s1_man_big  <= {man_big, 1'b0}; // 12-bit, guard bit

            // 小数尾数移位对齐
            s1_man_small_shifted <= {man_small, 4'b0} >> exp_diff_abs;    // 右移对齐
        end
    end

    // =========================================================================
    // Stage 2: ADD/SUB 运算
    // =========================================================================
    // ADD Path (同号路径):
    //   同号时, |A|+|B| = man_big + man_small (无符号加法)
    //   结果符号 = sign_a (与A,B相同)
    //
    // SUB Path (异号路径):
    //   异号时, |A|-|B| 或 |B|-|A| = man_big - man_small (无符号减法)
    //   结果符号取决于|A|和|B|的大小关系
    // =========================================================================

    assign man_align_flag = |s1_man_small_shifted[MAN_W+4:MAN_W+2];
    assign man_small_aligned = cal_percision ? s1_man_small_shifted[MAN_W+4:3] : {man_small, 1'b0};   // 保留高位  [14:3]



    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid <= cal_percision ? s1_valid : valid_in;

            // ---- ADD Path: Unsigned Addition (同号) ----
            s2_sum_add  <= {1'b0, s1_man_big} + {1'b0, man_small_aligned};
            s2_exp_add  <= s1_exp_max;
            // ADD结果符号: 同号时符号不变
            s2_sign_add <= s1_sign_a;

            // ---- SUB Path: Unsigned Subtraction (异号) ----
            s2_diff_sub <= s1_man_big - man_small_aligned;
            s2_sign_sub <= s1_a_ge_b ? s1_sign_a : ~s1_sign_a; // 大数符号
            s2_exp_sub <= s1_exp_max;
        end
    end

    // =========================================================================
    // Stage 3: Normalization (归一化)
    // =========================================================================
    // ADD Path — Simplified Norm. (简化归一化):
    //   同号加法最多产生1-bit溢出, 只需检查carry + 1-bit右移
    //   无需前导1检测器 (Leading-1 Detector) 和可变移位器
    //
    // SUB Path — Full Norm. (完整归一化):
    //   异号减法结果可能有多个前导零, 需要前导1检测 + 可变移位
    // =========================================================================

    // --- Two-stage Priority Encoder (O(log n) depth) ---
    // Stage 1: Find MSB in each 6-bit group
    wire [2:0] group_msb_5;  // bits[11:6] MSB position (3=not found in group)
    wire [2:0] group_msb_0;  // bits[5:0] MSB position
    wire       msb_in_upper;   // 1=upper group has MSB

    assign group_msb_5 =
        (s2_diff_sub[11]) ? 3'd5 :
        (s2_diff_sub[10]) ? 3'd4 :
        (s2_diff_sub[9])  ? 3'd3 :
        (s2_diff_sub[8])  ? 3'd2 :
        (s2_diff_sub[7])  ? 3'd1 :
        (s2_diff_sub[6])  ? 3'd0 : 3'd6;

    assign group_msb_0 =
        (s2_diff_sub[5])  ? 3'd5 :
        (s2_diff_sub[4])  ? 3'd4 :
        (s2_diff_sub[3])  ? 3'd3 :
        (s2_diff_sub[2])  ? 3'd2 :
        (s2_diff_sub[1])  ? 3'd1 :
        (s2_diff_sub[0])  ? 3'd0 : 3'd0;

    // Stage 2: Select correct group
    assign msb_in_upper = (group_msb_5 != 3'd6);
    assign sub_leading_pos = msb_in_upper ? (group_msb_5 + 3'd6) : group_msb_0;            

    wire [MAN_W+1:0] sub_shifted;
    assign sub_shifted = s2_diff_sub << (MAN_W + 1 - sub_leading_pos);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
        end else begin
            s3_valid <= s2_valid;

            // ---- ADD Path: Simplified Normalization ----
            if (s2_sum_add[MAN_W+2]) begin
                // Carry溢出: 右移1位, 指数+1
                s3_man_add_norm <= s2_sum_add[MAN_W+2:2]; // 丢掉LSB, 取[MAN_W+1:1]
                s3_exp_add_norm <= s2_exp_add + 1;
            end else begin
                // 无溢出: 直接取
                s3_man_add_norm <= s2_sum_add[MAN_W+1:1];
                s3_exp_add_norm <= s2_exp_add;
            end
            s3_sign_add_norm <= s2_sign_add;

            // ---- SUB Path: Full Normalization ----
            if (s2_diff_sub == 0) begin
                // 结果为零
                s3_man_sub_norm <= 0;
                s3_exp_sub_norm <= 0;
                s3_sign_sub_norm <= 1'b0;
            end else begin
                // 前导1检测 + 可变左移
                s3_man_sub_norm <= sub_shifted[MAN_W+1:1];
                s3_exp_sub_norm <= s2_exp_sub - (MAN_W + 1 - sub_leading_pos);
                s3_sign_sub_norm <= s2_sign_sub;
            end
        end
    end

    wire [FP_W-1 : 0] s3_merge_add;
    wire [FP_W-1 : 0] s3_merge_sub;

    assign s3_merge_add = cal_percision ? {s3_sign_add_norm, s3_exp_add_norm[EXP_W-1:0], s3_man_add_norm[MAN_W-1:0]}
                                        :  s2_sign_add ? {8'b0, s2_sign_add, ~s2_sum_add[INT8_W-1:1] + 1} : {8'b0, s2_sign_add, s2_sum_add[INT8_W-1:1]};
    assign s3_merge_sub = cal_percision ? {s3_sign_sub_norm, s3_exp_sub_norm[EXP_W-1:0], s3_man_sub_norm[MAN_W-1:0]}
                                        :  s2_sign_sub ? {8'b0, s2_sign_sub, ~s2_diff_sub[INT8_W-1:1] + 1} : {8'b0, s2_sign_sub, s2_diff_sub[INT8_W-1:1]} ;
    // =========================================================================
    // Stage 4: Post Sign Processing + 输出打包
    // =========================================================================
    // 论文中Post Sign Processing确保ADD和SUB的输出符号正确:
    //   - ADD Path: 同号运算, 符号直接取输入符号
    //   - SUB Path: 异号运算, 符号已在Stage 2中根据大小关系确定
    //   - 对于蝶形运算 A+B 和 A-B:
    //     result_add = |A| + |B| 的符号 (同号时) 或 |大| - |小| 的符号 (异号时)
    //     result_sub = A - B 的符号需要特殊处理
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_add <= 0;
            result_sub <= 0;
            valid_out  <= 1'b0;
        end else begin
            valid_out <= cal_percision ? s3_valid  : s2_valid;

            // ---- Pack A + B ----
            // 蝶形ADD输出: 始终输出A+B
            //   当同号时: sign = sign_a, result = |A|+|B|
            //   当异号时: sign = sign of larger, result = |大|-|小|
            //   对于A+B: 同号 → sign_a, 异号 → sign_a(若|A|>|B|) 或 sign_b(若|B|>|A|)
            result_add <= sign_a == sign_b ? s3_merge_add : s3_merge_sub;

            // ---- Pack A - B ----
            // 蝶形SUB输出: 输出A-B
            //   A-B的符号: 与A+B的符号可能不同
            //   同号时: A-B = |A|-|B|, sign由大小关系决定
            //   异号时: A-B = |A|+|B|, sign = sign_a
            result_sub <= sign_a == sign_b ? s3_merge_sub : s3_merge_add;
        end
    end

endmodule
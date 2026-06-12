//================================================================================
// File Name     : gather_top.v
// Project       : 
// Create Date   : 2026.04.10
// Description   :
// 
//--------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who               Description
// 0.5.0   2021.03.31              Modify transformation logic of Gather OP
//================================================================================

module hadamard (
    input                   gen_status    ,
    input                   fwht_status   ,
    input        [1 : 0]    trans_status  ,
    input                   wr_done       ,
    input                   cal_percision ,

    input        [511 : 0]  din           ,
    input                   din_valid     ,
    output                  din_ready     ,

    output       [511 : 0]  dout          ,
    output                  dout_valid    ,
    input                   dout_ready    ,
    
    //input      [ 15: 0]     arsize        ,
    input                   comp_done     ,

    output                  fwht_done     ,
    output                  rd_data_ready ,   // 读数据全部到达

    input                   clk           ,
    input                   rst_n
);

reg     [15:0]              fwht_regs   [63:0];
reg     [15:0]              fwht_out_regs [63:0]; 
reg     [1 : 0]             trans_status_reg;
reg     [1 : 0]             rd_cnt;
reg     [1 : 0]             wr_cnt;
wire    [511 : 0]           dout_lo;
wire    [511 : 0]           dout_hi;
wire    [511 : 0]           dout_int8;

wire    [511 : 0]           dout_rs    ;
wire                        dout_valid_rs  ;
wire                        dout_ready_rs  ;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        trans_status_reg <= #0.1 2'b00;
    end
    else begin
        trans_status_reg <= #0.1 trans_status;
    end
end

// 读计数器: 武装-解除机制, 每 pulse 只计一次
// armed=1 时 valid 上升沿触发计数, 然后武装解除; valid 下降沿重新武装
reg rd_armed;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_cnt    <= #0.1 2'd0;
        rd_armed  <= #0.1 1'b1;
    end
    else begin
        if(comp_done | fwht_status) begin
            rd_cnt   <= #0.1 2'd0;
            rd_armed <= #0.1 1'b1;
        end
        else if(din_valid & din_ready & rd_armed) begin
            rd_cnt   <= #0.1 rd_cnt + 2'd1;
            rd_armed <= #0.1 1'b0;
        end
        else if(~din_valid || ~din_ready) begin
            rd_armed <= #0.1 1'b1;
        end
    end
end

// rd_data_ready: 读数据全部到达 (rd_cnt >= 每块预期读数)
// FP16(cal_percision=1): 每块 2 DMA word → rd_cnt >= 2
// INT8(cal_percision=0): 每块 1 DMA word → rd_cnt >= 1
wire [1:0] rd_expected = cal_percision ? 2'd2 : 2'd1;
assign rd_data_ready = (rd_cnt >= rd_expected);


// 写计数器: 同样武装-解除机制
reg dout_valid_r;
reg wr_armed;

always @(posedge clk or negedge rst_n) begin 
    dout_valid_r <= #0.1 dout_valid;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_cnt   <= #0.1 2'd0;
        wr_armed <= #0.1 1'b1;
    end
    else begin
        if(comp_done | fwht_status) begin
            wr_cnt   <= #0.1 2'd0;
            wr_armed <= #0.1 1'b1;
        end
        else if(dout_valid & dout_ready & wr_armed) begin
            wr_cnt   <= #0.1 wr_cnt + 2'd1;
            wr_armed <= #0.1 1'b0;
        end
        else if(~dout_valid) begin
            wr_armed <= #0.1 1'b1;
        end
        else begin
            wr_cnt <= #0.1 wr_cnt;
        end
    end
end

// 支持int8和fp16两种格式的计算
// 写入用于FWHT的REG，INT8数据写入低8位
genvar i;
genvar j;

generate
for (i = 0; i < 32; i = i + 1) begin: fwht_regs_gen_0    
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            fwht_regs[i] <= #0.1 16'd0; 
        end
        else if(din_valid & din_ready & rd_cnt==2'd0) begin
            if(~cal_percision) begin
                // INT8 → INT16: 符号扩展, sign bit 推到 bit 15
                fwht_regs[i] <= #0.1 { {8{din[i*8+7]}}, din[i*8+7 : i*8] };
            end
            else begin
                fwht_regs[i] <= #0.1 din[i * 16 + 15 : i * 16];
            end
        end
        else begin
            fwht_regs[i] <= #0.1 fwht_regs[i];
        end
    end
end

for (j = 0; j < 32; j = j + 1) begin: fwht_regs_gen_1    
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            fwht_regs[j+32] <= #0.1 16'd0;
        end
        else if(din_valid & din_ready) begin
            if(~cal_percision & rd_cnt==2'd0) begin
                // INT8 → INT16: 符号扩展, sign bit 推到 bit 15
                fwht_regs[j+32] <= #0.1 { {8{din[(j+32)*8+7]}}, din[(j+32)*8+7 : (j+32)*8] };
            end
            else if(cal_percision & rd_cnt == 2'd1) begin
                fwht_regs[j+32] <= #0.1 din[j*16+15:j*16];
            end
            else begin
                fwht_regs[j+32] <= #0.1 fwht_regs[j+32];
            end
        end
        else begin
            fwht_regs[j+32] <= #0.1 fwht_regs[j+32];
        end
    end
end

endgenerate

// 6级FWHT共需要6个stage，stage0为输入
reg  [15:0]         stage0   [63:0];
reg  [15:0]         stage1   [63:0];
reg  [15:0]         stage2   [63:0];
reg  [15:0]         stage3   [63:0];
reg  [15:0]         stage4   [63:0];
reg  [15:0]         stage5   [63:0];
reg  [15:0]         stage6   [63:0];
wire                 s0_valid;
wire                 s1_valid;
wire                 s2_valid;
wire                 s3_valid;
wire                 s4_valid;
wire                 s5_valid;
wire                 s6_valid;
reg                  s0_valid_r;
reg                  s1_valid_r;
reg                  s2_valid_r;
reg                  s3_valid_r;
reg                  s4_valid_r;
reg                  s5_valid_r;
reg                  s6_valid_r;
wire                 s0_valid_pos;
wire                 s1_valid_pos;
wire                 s2_valid_pos;
wire                 s3_valid_pos;
wire                 s4_valid_pos;
wire                 s5_valid_pos;
wire                 s6_valid_pos;
reg                  s6_valid_pos_r;  // 仅保留 stage6 用于 w_reg_valid_pos

wire [15:0]         s_valid_out;
wire                s_valid_out_all;
reg                 s_valid_out_r;
reg [2:0]           stage_cnt;
wire sX_start = s0_valid_pos | s1_valid_pos | s2_valid_pos |
                s3_valid_pos | s4_valid_pos | s5_valid_pos;
reg  sX_start_r1, sX_start_r2;
wire s_valid_in;
assign s_valid_in = sX_start_r1 | sX_start_r2;  // sX_start延迟1拍, 连续两拍触发 PUB


reg                result_valid;
wire               w_reg_valid;
wire               w_reg_valid_pos;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        result_valid <= #0.1 1'b0;
    end
    else begin
        if(w_reg_valid_pos) begin
           result_valid <= #0.1 1'b1; 
        end
        else if(wr_cnt==2) begin
            result_valid <= #0.1 1'b0;
        end
        else begin
            result_valid <= #0.1 result_valid;
        end
    end
end

// Register stage0 on rising edge of fwht_status
reg fwht_status_r;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fwht_status_r <= 1'b0;
    end else begin
        fwht_status_r <= fwht_status;
    end
end

generate
    for (i = 0; i < 64; i = i + 1) begin
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage0[i] <= 16'b0;
            end else if (fwht_status && !fwht_status_r) begin
                stage0[i] <= fwht_regs[i];
            end
        end
    end
endgenerate

// s_valid[0] directly from fwht_status, s_valid[1-6] registered

assign w_reg_valid = s6_valid;
assign w_reg_valid_pos = s6_valid_pos_r;
assign s_valid_out_all = &s_valid_out;

assign s0_valid = fwht_status_r;
assign s1_valid = stage_cnt == 1;
assign s2_valid = stage_cnt == 2;
assign s3_valid = stage_cnt == 3;
assign s4_valid = stage_cnt == 4;
assign s5_valid = stage_cnt == 5;
assign s6_valid = stage_cnt == 6;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        s_valid_out_r <= 1'b0;
    end
    else begin
        s_valid_out_r <= s_valid_out_all;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        stage_cnt <= 3'd0;
    end
    else begin
        if(gen_status)
            stage_cnt <= 3'b0;
        else if(s_valid_out_all && s_valid_out_r)
            stage_cnt <= stage_cnt + 3'b1;  // g1捕获时推进
    end
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin sX_start_r1 <= 1'b0; sX_start_r2 <= 1'b0; end
    else       begin sX_start_r1 <= sX_start; sX_start_r2 <= sX_start_r1; end
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        s0_valid_r <= 1'b0;
        s1_valid_r <= 1'b0;
        s2_valid_r <= 1'b0;
        s3_valid_r <= 1'b0;
        s4_valid_r <= 1'b0;
        s5_valid_r <= 1'b0;
        s6_valid_r <= 1'b0;
        s6_valid_pos_r <= 1'b0;
    end
    else begin
        s0_valid_r <= s0_valid;
        s1_valid_r <= s1_valid;
        s2_valid_r <= s2_valid;
        s3_valid_r <= s3_valid;
        s4_valid_r <= s4_valid;
        s5_valid_r <= s5_valid;
        s6_valid_r <= s6_valid;
        s6_valid_pos_r <= s6_valid_pos;
    end
end

assign s0_valid_pos = s0_valid & ~s0_valid_r;
assign s1_valid_pos = s1_valid & ~s1_valid_r;
assign s2_valid_pos = s2_valid & ~s2_valid_r;
assign s3_valid_pos = s3_valid & ~s3_valid_r;
assign s4_valid_pos = s4_valid & ~s4_valid_r;
assign s5_valid_pos = s5_valid & ~s5_valid_r; 
assign s6_valid_pos = s6_valid & ~s6_valid_r;

// ============================================================
// 16 PUB 交织: group_sel 选 g0/g1 输入, valid_cyc 选 g0/g1 输出捕获
// ============================================================
generate
    for (i = 0; i < 16; i = i + 1) begin
        localparam I0 = i;
        localparam I1 = i + 16;
        localparam LO0_g0 = I0 * 2;
        localparam HI0_g0 = LO0_g0 + 1;
        localparam LO0_g1 = I1 * 2;
        localparam HI0_g1 = LO0_g1 + 1;
        localparam LO1_g0 = (I0%2)+(I0/2)*4;
        localparam HI1_g0 = LO1_g0 + 2;
        localparam LO1_g1 = (I1%2)+(I1/2)*4;
        localparam HI1_g1 = LO1_g1 + 2;
        localparam LO2_g0 = (I0%4)+(I0/4)*8;
        localparam HI2_g0 = LO2_g0 + 4;
        localparam LO2_g1 = (I1%4)+(I1/4)*8;
        localparam HI2_g1 = LO2_g1 + 4;
        localparam LO3_g0 = (I0%8)+(I0/8)*16;
        localparam HI3_g0 = LO3_g0 + 8;
        localparam LO3_g1 = (I1%8)+(I1/8)*16;
        localparam HI3_g1 = LO3_g1 + 8;
        localparam LO4_g0 = (I0%16)+(I0/16)*32;
        localparam HI4_g0 = LO4_g0 + 16;
        localparam LO4_g1 = (I1%16)+(I1/16)*32;
        localparam HI4_g1 = LO4_g1 + 16;
        localparam LO5_g0 = (I0%32)+(I0/32)*64;
        localparam HI5_g0 = LO5_g0 + 32;
        localparam LO5_g1 = (I1%32)+(I1/32)*64;
        localparam HI5_g1 = LO5_g1 + 32;

        wire [15:0] op_a_g0, op_a_g1;
        wire [15:0] op_b_g0, op_b_g1;
        wire [15:0] op_a, op_b;
        wire [15:0] result_add;
        wire [15:0] result_sub;
        reg  [15:0] op_a_r;
        reg  [15:0] op_b_r;
        reg  s_valid_in_r;

        // 6:1 per group: stage_cnt 直接索引, 省一级 sX_valid_r 寄存器延迟
        wire [3:0] sc = stage_cnt[2:0];
        assign op_a_g0 = (sc == 3'd5) ? stage5[LO5_g0] :
                         (sc == 3'd4) ? stage4[LO4_g0] :
                         (sc == 3'd3) ? stage3[LO3_g0] :
                         (sc == 3'd2) ? stage2[LO2_g0] :
                         (sc == 3'd1) ? stage1[LO1_g0] : stage0[LO0_g0];
        assign op_a_g1 = (sc == 3'd5) ? stage5[LO5_g1] :
                         (sc == 3'd4) ? stage4[LO4_g1] :
                         (sc == 3'd3) ? stage3[LO3_g1] :
                         (sc == 3'd2) ? stage2[LO2_g1] :
                         (sc == 3'd1) ? stage1[LO1_g1] : stage0[LO0_g1];
        assign op_b_g0 = (sc == 3'd5) ? stage5[HI5_g0] :
                         (sc == 3'd4) ? stage4[HI4_g0] :
                         (sc == 3'd3) ? stage3[HI3_g0] :
                         (sc == 3'd2) ? stage2[HI2_g0] :
                         (sc == 3'd1) ? stage1[HI1_g0] : stage0[HI0_g0];
        assign op_b_g1 = (sc == 3'd5) ? stage5[HI5_g1] :
                         (sc == 3'd4) ? stage4[HI4_g1] :
                         (sc == 3'd3) ? stage3[HI3_g1] :
                         (sc == 3'd2) ? stage2[HI2_g1] :
                         (sc == 3'd1) ? stage1[HI1_g1] : stage0[HI0_g1];

        // 6:1 mux 输出 → 寄存器 (切分长组合路径)
        reg [15:0] op_a_g0_r, op_a_g1_r, op_b_g0_r, op_b_g1_r;
        reg        s_valid_in_r1, s_valid_in_r2;

        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                op_a_g0_r <= 16'b0; op_a_g1_r <= 16'b0;
                op_b_g0_r <= 16'b0; op_b_g1_r <= 16'b0;
                s_valid_in_r1 <= 1'b0; s_valid_in_r2 <= 1'b0;
                op_a_r <= 16'b0; op_b_r <= 16'b0; s_valid_in_r <= 1'b0;
            end else if(gen_status) begin
                s_valid_in_r1 <= 1'b0; s_valid_in_r <= 1'b0;
            end else begin
                // Stage1: 锁存6:1 mux输出
                op_a_g0_r <= op_a_g0; op_a_g1_r <= op_a_g1;
                op_b_g0_r <= op_b_g0; op_b_g1_r <= op_b_g1;
                s_valid_in_r1 <= s_valid_in; s_valid_in_r2 <= s_valid_in_r1;
                // Stage2: 2:1 mux (边沿检测对齐延迟1拍的数据)
                op_a_r    <= (s_valid_in_r1 && !s_valid_in_r2) ? op_a_g0_r : op_a_g1_r;
                op_b_r    <= (s_valid_in_r1 && !s_valid_in_r2) ? op_b_g0_r : op_b_g1_r;
                s_valid_in_r <= s_valid_in_r1;
            end
        end

        fwht_pub #(.EXP_W(5), .MAN_W(13), .FP_W(16)) u_fwht_pub (
            .clk(clk), .rst_n(rst_n), .cal_percision(cal_percision),
            .op_a(op_a_r), .op_b(op_b_r), .valid_in(s_valid_in_r),
            .result_add(result_add), .result_sub(result_sub),
            .valid_out(s_valid_out[i])
        );

        // Stage 1 capture (s_valid_out_all && stage_cnt==0)
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage1[LO0_g0] <= 16'b0;
                stage1[HI0_g0] <= 16'b0;
                stage1[LO0_g1] <= 16'b0;
                stage1[HI0_g1] <= 16'b0;
            end else if (s_valid_out_all && stage_cnt == 3'd0) begin
                if (!s_valid_out_r) begin
                    stage1[LO0_g0] <= result_add;
                    stage1[HI0_g0] <= result_sub;
                    stage1[LO0_g1] <= 16'b0;
                    stage1[HI0_g1] <= 16'b0;
                end else begin
                    stage1[LO0_g0] <= stage1[LO0_g0];
                    stage1[HI0_g0] <= stage1[HI0_g0];
                    stage1[LO0_g1] <= result_add;
                    stage1[HI0_g1] <= result_sub;
                end
            end
        end

        // Stage 2 capture (s_valid_out_all && stage_cnt==1)
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage2[LO1_g0] <= 16'b0;
                stage2[HI1_g0] <= 16'b0;
                stage2[LO1_g1] <= 16'b0;
                stage2[HI1_g1] <= 16'b0;
            end else if (s_valid_out_all && stage_cnt == 3'd1) begin
                if (!s_valid_out_r) begin
                    stage2[LO1_g0] <= result_add;
                    stage2[HI1_g0] <= result_sub;
                    stage2[LO1_g1] <= 16'b0;
                    stage2[HI1_g1] <= 16'b0;
                end else begin
                    stage2[LO1_g0] <= stage2[LO1_g0];
                    stage2[HI1_g0] <= stage2[HI1_g0];
                    stage2[LO1_g1] <= result_add;
                    stage2[HI1_g1] <= result_sub;
                end
            end
        end

        // Stage 3 capture (s_valid_out_all && stage_cnt==2)
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage3[LO2_g0] <= 16'b0;
                stage3[HI2_g0] <= 16'b0;
                stage3[LO2_g1] <= 16'b0;
                stage3[HI2_g1] <= 16'b0;
            end else if (s_valid_out_all && stage_cnt == 3'd2) begin
                if (!s_valid_out_r) begin
                    stage3[LO2_g0] <= result_add;
                    stage3[HI2_g0] <= result_sub;
                    stage3[LO2_g1] <= 16'b0;
                    stage3[HI2_g1] <= 16'b0;
                end else begin
                    stage3[LO2_g0] <= stage3[LO2_g0];
                    stage3[HI2_g0] <= stage3[HI2_g0];
                    stage3[LO2_g1] <= result_add;
                    stage3[HI2_g1] <= result_sub;
                end
            end
        end

        // Stage 4 capture (s_valid_out_all && stage_cnt==3)
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage4[LO3_g0] <= 16'b0;
                stage4[HI3_g0] <= 16'b0;
                stage4[LO3_g1] <= 16'b0;
                stage4[HI3_g1] <= 16'b0;
            end else if (s_valid_out_all && stage_cnt == 3'd3) begin
                if (!s_valid_out_r) begin
                    stage4[LO3_g0] <= result_add;
                    stage4[HI3_g0] <= result_sub;
                    stage4[LO3_g1] <= 16'b0;
                    stage4[HI3_g1] <= 16'b0;
                end else begin
                    stage4[LO3_g0] <= stage4[LO3_g0];
                    stage4[HI3_g0] <= stage4[HI3_g0];
                    stage4[LO3_g1] <= result_add;
                    stage4[HI3_g1] <= result_sub;
                end
            end
        end

        // Stage 5 capture (s_valid_out_all && stage_cnt==4)
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage5[LO4_g0] <= 16'b0;
                stage5[HI4_g0] <= 16'b0;
                stage5[LO4_g1] <= 16'b0;
                stage5[HI4_g1] <= 16'b0;
            end else if (s_valid_out_all && stage_cnt == 3'd4) begin
                if (!s_valid_out_r) begin
                    stage5[LO4_g0] <= result_add;
                    stage5[HI4_g0] <= result_sub;
                    stage5[LO4_g1] <= 16'b0;
                    stage5[HI4_g1] <= 16'b0;
                end else begin
                    stage5[LO4_g0] <= stage5[LO4_g0];
                    stage5[HI4_g0] <= stage5[HI4_g0];
                    stage5[LO4_g1] <= result_add;
                    stage5[HI4_g1] <= result_sub;
                end
            end
        end

        // Stage 6 capture (s_valid_out_all && stage_cnt==5)
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage6[LO5_g0] <= 16'b0;
                stage6[HI5_g0] <= 16'b0;
                stage6[LO5_g1] <= 16'b0;
                stage6[HI5_g1] <= 16'b0;
            end else if (s_valid_out_all && stage_cnt == 3'd5) begin
                if (!s_valid_out_r) begin
                    stage6[LO5_g0] <= result_add;
                    stage6[HI5_g0] <= result_sub;
                    stage6[LO5_g1] <= 16'b0;
                    stage6[HI5_g1] <= 16'b0;
                end else begin
                    stage6[LO5_g0] <= stage6[LO5_g0];
                    stage6[HI5_g0] <= stage6[HI5_g0];
                    stage6[LO5_g1] <= result_add;
                    stage6[HI5_g1] <= result_sub;
                end
            end
        end
    end
endgenerate

generate
    for (i = 0; i < 64; i = i + 1) begin
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                fwht_out_regs[i] <= #0.1 16'd0;
            end
            else begin
                if(w_reg_valid_pos) begin
                    fwht_out_regs[i] <= #0.1 stage6[i];
                end
                else begin
                    fwht_out_regs[i] <= #0.1 fwht_out_regs[i];
                end
            end
        end
    end
endgenerate

assign dout_lo = {fwht_out_regs[31], fwht_out_regs[30], fwht_out_regs[29], fwht_out_regs[28], fwht_out_regs[27], fwht_out_regs[26], 
                  fwht_out_regs[25], fwht_out_regs[24], fwht_out_regs[23], fwht_out_regs[22], fwht_out_regs[21], fwht_out_regs[20],
                  fwht_out_regs[19], fwht_out_regs[18], fwht_out_regs[17], fwht_out_regs[16], fwht_out_regs[15], fwht_out_regs[14],
                  fwht_out_regs[13], fwht_out_regs[12], fwht_out_regs[11], fwht_out_regs[10], fwht_out_regs[9], fwht_out_regs[8],
                  fwht_out_regs[7], fwht_out_regs[6], fwht_out_regs[5], fwht_out_regs[4], fwht_out_regs[3], fwht_out_regs[2],
                  fwht_out_regs[1], fwht_out_regs[0]};
assign dout_hi = {fwht_out_regs[63], fwht_out_regs[62], fwht_out_regs[61], fwht_out_regs[60], fwht_out_regs[59], fwht_out_regs[58], 
                  fwht_out_regs[57], fwht_out_regs[56], fwht_out_regs[55], fwht_out_regs[54], fwht_out_regs[53], fwht_out_regs[52],
                  fwht_out_regs[51], fwht_out_regs[50], fwht_out_regs[49], fwht_out_regs[48], fwht_out_regs[47], fwht_out_regs[46],
                  fwht_out_regs[45], fwht_out_regs[44], fwht_out_regs[43], fwht_out_regs[42], fwht_out_regs[41], fwht_out_regs[40],
                  fwht_out_regs[39], fwht_out_regs[38], fwht_out_regs[37], fwht_out_regs[36], fwht_out_regs[35], fwht_out_regs[34],
                  fwht_out_regs[33], fwht_out_regs[32]};
assign dout_int8 = {fwht_out_regs[63][7:0], fwht_out_regs[62][7:0], fwht_out_regs[61][7:0], fwht_out_regs[60][7:0], fwht_out_regs[59][7:0], 
                    fwht_out_regs[58][7:0], fwht_out_regs[57][7:0], fwht_out_regs[56][7:0], fwht_out_regs[55][7:0], fwht_out_regs[54][7:0],
                    fwht_out_regs[53][7:0], fwht_out_regs[52][7:0], fwht_out_regs[51][7:0], fwht_out_regs[50][7:0], fwht_out_regs[49][7:0],
                    fwht_out_regs[48][7:0], fwht_out_regs[47][7:0], fwht_out_regs[46][7:0], fwht_out_regs[45][7:0], fwht_out_regs[44][7:0],
                    fwht_out_regs[43][7:0], fwht_out_regs[42][7:0], fwht_out_regs[41][7:0], fwht_out_regs[40][7:0], fwht_out_regs[39][7:0],
                    fwht_out_regs[38][7:0], fwht_out_regs[37][7:0], fwht_out_regs[36][7:0], fwht_out_regs[35][7:0], fwht_out_regs[34][7:0],
                    fwht_out_regs[33][7:0], fwht_out_regs[32][7:0], fwht_out_regs[31][7:0], fwht_out_regs[30][7:0], fwht_out_regs[29][7:0],
                    fwht_out_regs[28][7:0], fwht_out_regs[27][7:0], fwht_out_regs[26][7:0], fwht_out_regs[25][7:0], fwht_out_regs[24][7:0],
                    fwht_out_regs[23][7:0], fwht_out_regs[22][7:0], fwht_out_regs[21][7:0], fwht_out_regs[20][7:0], fwht_out_regs[19][7:0],
                    fwht_out_regs[18][7:0], fwht_out_regs[17][7:0], fwht_out_regs[16][7:0], fwht_out_regs[15][7:0], fwht_out_regs[14][7:0],
                    fwht_out_regs[13][7:0], fwht_out_regs[12][7:0], fwht_out_regs[11][7:0], fwht_out_regs[10][7:0], fwht_out_regs[9][7:0],
                    fwht_out_regs[8][7:0], fwht_out_regs[7][7:0], fwht_out_regs[6][7:0], fwht_out_regs[5][7:0], fwht_out_regs[4][7:0],
                    fwht_out_regs[3][7:0], fwht_out_regs[2][7:0], fwht_out_regs[1][7:0], fwht_out_regs[0][7:0]};

assign din_ready = trans_status[0];

// ---- 输出状态机: 握手上升沿触发转移 + valid 立即拉低 ----
reg [1:0] out_phase;   // 0=IDLE, 1=LO, 2=GAP, 3=HI
reg [1:0] gap_cnt;
wire      dout_hs     = dout_valid & dout_ready;
reg       dout_hs_r;
wire      dout_hs_pos;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) dout_hs_r <= #0.1 1'b0;
    else         dout_hs_r <= #0.1 dout_hs;
end
assign dout_hs_pos = dout_hs & ~dout_hs_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        out_phase <= #0.1 2'd0; gap_cnt <= #0.1 2'd0;
    end else if (comp_done) begin
        out_phase <= #0.1 2'd0; gap_cnt <= #0.1 2'd0;
    end else begin
        case (out_phase)
            2'd0: if (w_reg_valid_pos)           out_phase <= #0.1 2'd1;
            2'd1: if (dout_hs_pos) begin
                if (cal_percision) begin
                    out_phase <= #0.1 2'd2; gap_cnt <= #0.1 2'd0;
                end else
                    out_phase <= #0.1 2'd0;
            end
            2'd2: if (gap_cnt == 2'd2) begin
                out_phase <= #0.1 2'd3;
            end else begin
                gap_cnt <= #0.1 gap_cnt + 2'd1;
            end
            2'd3: if (dout_hs_pos)               out_phase <= #0.1 2'd0;
            default:                             out_phase <= #0.1 2'd0;
        endcase
    end
end
// valid: LO/HI 状态下, 握手发生后立即拉低 (防 AVR 重复捕获)
assign dout_valid_rs = ((out_phase == 2'd1 || out_phase == 2'd3) && !dout_hs) && trans_status[1];
assign dout_rs = cal_percision ? (out_phase == 2'd3 ? dout_hi : dout_lo) : dout_int8;
assign fwht_done = result_valid;

// 实例化 AVR 寄存器切片模块 (avr_rs)
// 作用：隔离组合逻辑路径，改善时序，并提供背压处理能力
avr_rs #(.DW(512)) U_avr_rs(
    .m_data      ( dout_rs         ),// I - 主接口数据输入
    .m_valid     ( dout_valid_rs   ),// I - 主接口有效信号
    .m_ready     ( dout_ready_rs   ),// O - 主接口就绪信号

    .s_data      ( dout            ),// O - 从接口数据输出
    .s_valid     ( dout_valid      ),// O - 从接口有效信号
    .s_ready     ( dout_ready      ),// I - 从接口就绪信号

    .clk         ( clk            ),
    .rst_n       ( rst_n          )
);


endmodule
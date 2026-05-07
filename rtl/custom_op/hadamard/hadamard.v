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

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_cnt <= #0.1 2'd0;
    end
    else begin
        if(din_valid & din_ready) begin
            rd_cnt <= #0.1 rd_cnt + 2'd1;
        end
        else if(comp_done | fwht_status) begin
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
        else if(comp_done | fwht_status) begin
            //算子处理完成或写入完毕后，清零计数器
            wr_cnt <= #0.1 2'd0;
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
                fwht_regs[i] <= #0.1 {8'b0, din[i * 8 + 7 : i * 8]};
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
                fwht_regs[j+32] <= #0.1 {8'b0, din[(j + 32) * 8 + 7 : (j + 32) * 8]};
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
reg                  s0_valid_pos_r;
reg                  s1_valid_pos_r;
reg                  s2_valid_pos_r;
reg                  s3_valid_pos_r;
reg                  s4_valid_pos_r;
reg                  s5_valid_pos_r;
reg                  s6_valid_pos_r;

wire [31:0]         s_valid_out;
wire                s_valid_out_all;
reg                 s_valid_out_r;
reg [2:0]           stage_cnt;


reg                w_reg_valid_r;
reg                result_valid;
wire               w_reg_valid;
wire               w_reg_valid_pos; 

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        w_reg_valid_r <= #0.1 1'b0;
    end
    else begin
        w_reg_valid_r <= #0.1 w_reg_valid;
    end
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        result_valid <= #0.1 1'b0;
    end
    else begin
        if(w_reg_valid_pos) begin
           result_valid <= #0.1 1'b1; 
        end
        else if(wr_done) begin
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
        if(gen_status) begin
            stage_cnt <= 3'b0;
        end
        else if(s_valid_out_all & ~s_valid_out_r) begin
            stage_cnt <= stage_cnt + 3'b1; //最高到6
        end
    end
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
        s0_valid_pos_r <= 1'b0;
        s1_valid_pos_r <= 1'b0;
        s2_valid_pos_r <= 1'b0;
        s3_valid_pos_r <= 1'b0;
        s4_valid_pos_r <= 1'b0;
        s5_valid_pos_r <= 1'b0;
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
        s0_valid_pos_r <= s0_valid_pos;
        s1_valid_pos_r <= s1_valid_pos;
        s2_valid_pos_r <= s2_valid_pos;
        s3_valid_pos_r <= s3_valid_pos;
        s4_valid_pos_r <= s4_valid_pos;
        s5_valid_pos_r <= s5_valid_pos;
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
// Stage 0-5: 32 butterflies per stage, captured on valid_out rising edge
// ============================================================
generate
    for (i = 0; i < 32; i = i + 1) begin
        localparam LO0 = i * 2;
        localparam HI0 = LO0 + 1;
        localparam LO1 = (i % 2) + (i / 2) * 4;
        localparam HI1 = LO1 + 2;
        localparam LO2 = (i % 4) + (i / 4) * 8;
        localparam HI2 = LO2 + 4;
        localparam LO3 = (i % 8) + (i / 8) * 16;
        localparam HI3 = LO3 + 8;
        localparam LO4 = (i % 16) + (i / 16) * 32;
        localparam HI4 = LO4 + 16;
        localparam LO5 = (i % 32) + (i / 32) * 64;
        localparam HI5 = LO5 + 32;

        wire [15:0] op_a;
        wire [15:0] op_b;
        wire        s_valid_in;
        wire [15:0] result_add;
        wire [15:0] result_sub;
        reg  [15:0] op_a_r;
        reg  [15:0] op_b_r;
        reg  s_valid_in_r;
        assign op_a = s5_valid_r ? stage5[LO5] :
                      s4_valid_r ? stage4[LO4] :
                      s3_valid_r ? stage3[LO3] :
                      s2_valid_r ? stage2[LO2] :
                      s1_valid_r ? stage1[LO1] :
                      s0_valid_r ? stage0[LO0] : 16'd0;

                      
        assign op_b = s5_valid_r ? stage5[HI5] :
                      s4_valid_r ? stage4[HI4] :
                      s3_valid_r ? stage3[HI3] :
                      s2_valid_r ? stage2[HI2] :
                      s1_valid_r ? stage1[HI1] :
                      s0_valid_r ? stage0[HI0] : 16'd0;

        assign s_valid_in = s0_valid_pos_r | s1_valid_pos_r | s2_valid_pos_r | 
                            s3_valid_pos_r | s4_valid_pos_r | s5_valid_pos_r ;


        always @(posedge clk or negedge rst_n) begin
            if(!rst_n)begin
                op_a_r <= 16'b0;
                op_b_r <= 16'b0;
                s_valid_in_r <= 1'b0;
            end
            else begin
                op_a_r <= op_a;
                op_b_r <= op_b;
                s_valid_in_r <= s_valid_in; 
            end
        end

        fwht_pub #(
            .EXP_W(5),
            .MAN_W(10),
            .FP_W(16)
        ) u_fwht_pub (
            .clk            (clk),
            .rst_n          (rst_n),
            .cal_percision  (cal_percision),
            .op_a           (op_a_r),
            .op_b           (op_b_r),
            .valid_in       (s_valid_in_r),
            .result_add     (result_add),
            .result_sub     (result_sub),
            .valid_out      (s_valid_out[i])
        );

        // Stage 1 capture on s1_valid rising edge
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage1[LO0] <= 16'b0;
                stage1[HI0] <= 16'b0;
            end else if (s1_valid_pos) begin
                stage1[LO0] <= result_add;
                stage1[HI0] <= result_sub;
            end
        end

        // Stage 2 capture on s2_valid rising edge
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage2[LO1] <= 16'b0;
                stage2[HI1] <= 16'b0;
            end else if (s2_valid_pos) begin
                stage2[LO1] <= result_add;
                stage2[HI1] <= result_sub;
            end
        end

        // Stage 3 capture on s3_valid rising edge
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage3[LO2] <= 16'b0;
                stage3[HI2] <= 16'b0;
            end else if (s3_valid_pos) begin
                stage3[LO2] <= result_add;
                stage3[HI2] <= result_sub;
            end
        end

        // Stage 4 capture on s4_valid rising edge
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage4[LO3] <= 16'b0;
                stage4[HI3] <= 16'b0;
            end else if (s4_valid_pos) begin
                stage4[LO3] <= result_add;
                stage4[HI3] <= result_sub;
            end
        end

        // Stage 5 capture on s5_valid rising edge
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage5[LO4] <= 16'b0;
                stage5[HI4] <= 16'b0;
            end else if (s5_valid_pos) begin
                stage5[LO4] <= result_add;
                stage5[HI4] <= result_sub;
            end
        end

        // Stage 6 capture on s6_valid rising edge
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stage6[LO5] <= 16'b0;
                stage6[HI5] <= 16'b0;
            end else if (s6_valid_pos) begin
                stage6[LO5] <= result_add;
                stage6[HI5] <= result_sub;
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
assign dout_rs = cal_percision ? (wr_cnt == 0 ? dout_lo : dout_hi) : dout_int8;
assign dout_valid_rs  = result_valid && trans_status[1];
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
//================================================================================
// Orgnization   : School of Electronic Science, NUDT
// File Name     : resize_fsm.v
// Author        : Changtai Lin
// Project       :
// Create Date   : 2026.04.27
// Description   : Resize FSM with axis pre-calibration and calibration state
//
//--------------------------------------------------------------------------------
// Modification History :
//================================================================================

module resize_fsm (
    input               rd_done,
    input               wr_done,
    input               rs_comp_start,   // resize start signal

    // Address generation signals
    input [31:0]        arbase_rs_gen,
    input [31:0]        arbase_rs_gen_2,
    input [15:0]        arsize_rs_gen,
    input [31:0]        awbase_rs_gen,
    input [15:0]        awsize_rs_gen,
    input               rs_addr_gen_valid,
    input               rs_first_line,
    input               rs_last_line,
    input               resize_done,     // resize operation complete
    input               axis_done,       // axis calibration complete
    input               axis_pre_cal_done,// axis pre-calculation complete

    output reg [31:0]   arbase,
    output reg [15:0]   arsize,
    output reg [31:0]   awbase,
    output reg [15:0]   awsize,

    output reg          rd_start,
    output reg          wr_start,
    output reg          rd_second,      // 读取第二行数据信号(用于双线性插值)
    output reg          comp_done,

    //MSB: WR; LSB: RD
    output reg [1:0]    trans_status,
    output reg          gen_status,
    output reg          axis_pre_cal,    // axis pre-calculation status
    output reg          axis_cal_status, // axis calibration status
    output reg          resize_status,   // resize operation status

    input               clk,
    input               rst_n
);

// 状态机状态定义
localparam  IDLE = 4'd0          ;
localparam  AXIS_PRE = 4'd1      ;  // 轴预计算状态: 计算裁剪区域和缩放比例
localparam  AXIS_CAL = 4'd2      ;  // 轴计算状态: 使用预计算结果计算像素坐标
localparam  GEN_ADDR = 4'd3      ;
localparam  RD_ONLY = 4'd4       ;
localparam  RD_SECONE = 4'd5     ;  // 读取第二行数据(用于双线性插值)
localparam  RESIZE = 4'd6        ;
localparam  WR_PIPELINE = 4'd7   ;
localparam  WR_ONLY = 4'd8       ;
localparam  COMP_DONE = 4'd9     ;

reg         rd_done_reg;
reg         wr_done_reg;
reg [31:0]  arbase_rs_gen_reg;
reg [31:0]  arbase_rs_gen_2_reg;
reg [15:0]  arsize_rs_gen_reg;
reg [31:0]  awbase_rs_gen_reg;
reg [15:0]  awsize_rs_gen_reg;
reg [1:0]   rd_cnt;               // 读完成计数器，用于双线性插值读两行数据

reg [3:0]   state;
reg [3:0]   next_state;

reg         wr_start_pulse_gen;
reg         rd_start_pulse_gen;

wire        wr_ddr;
wire        rd_ddr;

assign wr_ddr = (state == WR_PIPELINE) | (state == WR_ONLY);
assign rd_ddr = (state == WR_PIPELINE) | (state == RD_ONLY) | (state == RD_SECONE);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_start <= #0.1 1'b0;
        wr_start_pulse_gen <= #0.1 1'b0;
    end
    else begin
        if(wr_ddr) begin
            if(!wr_start_pulse_gen) begin
                wr_start <= #0.1 1'b1;
                wr_start_pulse_gen <= #0.1 1'b1;
            end
            else begin
                wr_start <= #0.1 1'b0;
                wr_start_pulse_gen <= #0.1 wr_start_pulse_gen;
            end
        end
        else begin
            wr_start_pulse_gen <= #0.1 1'b0;
            wr_start <= #0.1 1'b0;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_start <= #0.1 1'b0;
        rd_start_pulse_gen <= #0.1 1'b0;
    end
    else begin
        if(rd_ddr) begin
            if(!rd_start_pulse_gen) begin
                rd_start <= #0.1 1'b1;
                rd_start_pulse_gen <= #0.1 1'b1;
            end
            else begin
                rd_start <= #0.1 1'b0;
                rd_start_pulse_gen <= #0.1 rd_start_pulse_gen;
            end
        end
        else begin
            rd_start_pulse_gen <= #0.1 1'b0;
            rd_start <= #0.1 1'b0;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        rd_done_reg <= #0.1 1'b0;
    else if(rd_done)
        rd_done_reg <= #0.1 1'b1;
    else if(state == GEN_ADDR)
        rd_done_reg <= #0.1 1'b0;
    else
        rd_done_reg <= #0.1 rd_done_reg;
end

// rd_cnt: 读完成计数器，rd_cnt==2时完成两行读取
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        rd_cnt <= #0.1 2'd0;
    else if(state == GEN_ADDR)
        rd_cnt <= #0.1 2'd0;
    else if(rd_done)
        rd_cnt <= #0.1 rd_cnt + 2'd1;
    else
        rd_cnt <= #0.1 rd_cnt;
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        wr_done_reg <= #0.1 1'b0;
    else if(wr_done)
        wr_done_reg <= #0.1 1'b1;
    else if(state == GEN_ADDR)
        wr_done_reg <= #0.1 1'b0;
    else
        wr_done_reg <= #0.1 wr_done_reg;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        arbase_rs_gen_reg <= #0.1 32'd0;
        arsize_rs_gen_reg <= #0.1 16'd0;
        awbase_rs_gen_reg <= #0.1 32'd0;
        awsize_rs_gen_reg <= #0.1 16'd0;
        arbase_rs_gen_2_reg <= #0.1 32'd0;
    end
    else begin
        if(state == GEN_ADDR) begin
            arbase_rs_gen_reg <= #0.1 arbase_rs_gen;
            arsize_rs_gen_reg <= #0.1 arsize_rs_gen;
            awbase_rs_gen_reg <= #0.1 awbase_rs_gen;
            awsize_rs_gen_reg <= #0.1 awsize_rs_gen;
            arbase_rs_gen_2_reg <= #0.1 arbase_rs_gen_2;
        end
        else begin
            arbase_rs_gen_reg <= #0.1 arbase_rs_gen_reg;
            arsize_rs_gen_reg <= #0.1 arsize_rs_gen_reg;
            awbase_rs_gen_reg <= #0.1 awbase_rs_gen_reg;
            awsize_rs_gen_reg <= #0.1 awsize_rs_gen_reg;
            arbase_rs_gen_2_reg <= #0.1 arbase_rs_gen_2_reg;
        end
    end
end

// 状态转移逻辑
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= #0.1 IDLE;
    end else begin
        state <= #0.1 next_state;
    end
end

// 状态转换条件
// 状态转移: IDLE → AXIS_PRE → AXIS_CAL → GEN_ADDR → RESIZE → AXIS_CAL → GEN_ADDR → ...
always @(*) begin
    next_state = state; // Default keep current state
    case (state)
        IDLE: begin
            if (rs_comp_start) begin
                next_state = AXIS_PRE;
            end
        end
        AXIS_PRE: begin
            // 预计算完成后进入AXIS_CAL状态
            if (axis_pre_cal_done) begin
                next_state = AXIS_CAL;
            end
        end
        AXIS_CAL: begin
            // 轴计算完成
            if (axis_done) begin
                next_state = GEN_ADDR;
            end
        end
        GEN_ADDR: begin
            if (rs_addr_gen_valid) begin
                next_state = rs_first_line ? RD_ONLY : rs_last_line ? WR_ONLY : WR_PIPELINE;
            end
        end
        RD_ONLY: begin
            if (rd_done_reg) begin
                next_state = RD_SECONE;
            end
        end
        RD_SECONE: begin
            if (rd_cnt == 2'd2) begin
                next_state = RESIZE;
            end
        end
        RESIZE: begin
            // RESIZE完成后重新进入AXIS_CAL,为下一行计算坐标
            if (resize_done) begin
                next_state = AXIS_CAL;
            end
        end
        WR_PIPELINE: begin
            if (rd_done_reg && wr_done_reg) begin
                next_state = RD_SECONE;
            end
        end
        WR_ONLY: begin
            if (wr_done_reg) begin
                next_state = COMP_DONE;
            end
        end
        COMP_DONE: begin
            next_state = IDLE;
        end
        default: begin
            next_state = IDLE;
        end
    endcase
end

// 输出逻辑
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        arbase <= #0.1 32'd0;
        arsize <= #0.1 16'd0;
        awbase <= #0.1 32'd0;
        awsize <= #0.1 16'd0;
        comp_done <= #0.1 1'b0;
        trans_status <= #0.1 2'b00;
        rd_second <= #0.1 1'b0;
        gen_status <= #0.1 1'd0;
        axis_pre_cal <= #0.1 1'b0;
        axis_cal_status <= #0.1 1'b0;
        resize_status <= #0.1 1'b0;
    end
    else begin
        case (state)
            IDLE: begin
                arbase <= #0.1 32'd0;
                arsize <= #0.1 16'd0;
                awbase <= #0.1 32'd0;
                awsize <= #0.1 16'd0;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b00;
                rd_second <= #0.1 1'b0;
                gen_status <= #0.1 1'd0;
                axis_pre_cal <= #0.1 1'b0;
                axis_cal_status <= #0.1 1'b0;
                resize_status <= #0.1 1'b0;
            end
            AXIS_PRE: begin
                // 预计算状态: 计算裁剪区域和缩放比例
                arbase <= #0.1 32'd0;
                arsize <= #0.1 16'd0;
                awbase <= #0.1 32'd0;
                awsize <= #0.1 16'd0;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b00;
                rd_second <= #0.1 1'b0;
                gen_status <= #0.1 1'd0;
                axis_pre_cal <= #0.1 1'b1;  // 预计算信号拉高
                axis_cal_status <= #0.1 1'b0;
                resize_status <= #0.1 1'b0;
            end
            AXIS_CAL: begin
                // 轴计算状态: 使用预计算结果计算像素坐标
                arbase <= #0.1 32'd0;
                arsize <= #0.1 16'd0;
                awbase <= #0.1 32'd0;
                awsize <= #0.1 16'd0;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b00;
                rd_second <= #0.1 1'b0;
                gen_status <= #0.1 1'd0;
                axis_pre_cal <= #0.1 1'b0;
                axis_cal_status <= #0.1 1'b1;  // 轴计算信号拉高
                resize_status <= #0.1 1'b0;
            end
            GEN_ADDR: begin
                arbase <= #0.1 arbase;
                arsize <= #0.1 arsize;
                awbase <= #0.1 awbase;
                awsize <= #0.1 awsize;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b00;
                rd_second <= #0.1 1'b0;
                gen_status <= #0.1 1'b1;
                axis_pre_cal <= #0.1 1'b0;
                axis_cal_status <= #0.1 1'b0;
                resize_status <= #0.1 1'b0;
            end
            RD_ONLY: begin
                arbase <= #0.1 arbase_rs_gen_reg;
                arsize <= #0.1 arsize_rs_gen_reg;
                awbase <= #0.1 32'd0;
                awsize <= #0.1 16'd0;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b01;
                rd_second <= #0.1 1'b0;
                gen_status <= #0.1 1'd0;
                axis_pre_cal <= #0.1 1'b0;
                axis_cal_status <= #0.1 1'b0;
                resize_status <= #0.1 1'b0;
            end
            RD_SECONE: begin
                // 读取下一行数据(用于双线性插值的第二行)
                arbase <= #0.1 arbase_rs_gen_2_reg;  // 下一行地址偏移
                arsize <= #0.1 arsize_rs_gen_reg;
                awbase <= #0.1 32'd0;
                awsize <= #0.1 16'd0;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b01;
                rd_second <= #0.1 1'b1;  // 标记读取第二行
                gen_status <= #0.1 1'd0;
                axis_pre_cal <= #0.1 1'b0;
                axis_cal_status <= #0.1 1'b0;
                resize_status <= #0.1 1'b0;
            end
            RESIZE: begin
                arbase <= #0.1 arbase;
                arsize <= #0.1 arsize;
                awbase <= #0.1 awbase;
                awsize <= #0.1 awsize;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b00;
                rd_second <= #0.1 1'b0;
                gen_status <= #0.1 1'd0;
                axis_pre_cal <= #0.1 1'b0;
                axis_cal_status <= #0.1 1'b0;
                resize_status <= #0.1 1'b1;
            end
            WR_PIPELINE: begin
                arbase <= #0.1 arbase_rs_gen_reg;
                arsize <= #0.1 arsize_rs_gen_reg;
                awbase <= #0.1 awbase_rs_gen_reg;
                awsize <= #0.1 awsize_rs_gen_reg;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b11;
                rd_second <= #0.1 1'b0;
                gen_status <= #0.1 1'd0;
                axis_pre_cal <= #0.1 1'b0;
                axis_cal_status <= #0.1 1'b0;
                resize_status <= #0.1 1'b0;
            end
            WR_ONLY: begin
                arbase <= #0.1 32'b0;
                arsize <= #0.1 16'b0;
                awbase <= #0.1 awbase_rs_gen_reg;
                awsize <= #0.1 awsize_rs_gen_reg;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b10;
                rd_second <= #0.1 1'b0;
                gen_status <= #0.1 1'd0;
                axis_pre_cal <= #0.1 1'b0;
                axis_cal_status <= #0.1 1'b0;
                resize_status <= #0.1 1'b0;
            end
            COMP_DONE: begin
                arbase <= #0.1 32'b0;
                arsize <= #0.1 16'b0;
                awbase <= #0.1 32'b0;
                awsize <= #0.1 32'b0;
                comp_done <= #0.1 1'b1;
                trans_status <= #0.1 2'b00;
                rd_second <= #0.1 1'b0;
                gen_status <= #0.1 1'd0;
                axis_pre_cal <= #0.1 1'b0;
                axis_cal_status <= #0.1 1'b0;
                resize_status <= #0.1 1'b0;
            end
            default: begin
                arbase <= #0.1 32'b0;
                arsize <= #0.1 16'b0;
                awbase <= #0.1 32'b0;
                awsize <= #0.1 32'b0;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b00;
                rd_second <= #0.1 1'b0;
                gen_status <= #0.1 1'd0;
                axis_pre_cal <= #0.1 1'b0;
                axis_cal_status <= #0.1 1'b0;
                resize_status <= #0.1 1'b0;
            end
        endcase
    end
end

endmodule
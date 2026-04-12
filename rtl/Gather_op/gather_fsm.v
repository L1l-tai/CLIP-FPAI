//================================================================================
// Orgnization   : School of Electronic Science, NUDT
// File Name     : gather_top.v
// Author        : Changtai Lin
// Project       : 
// Create Date   : 2026.04.10
// Description   :
// 
//--------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who               Description
// 0.5.0   2021.03.31   Changtai Lin      Modify transformation logic of Gather OP
//================================================================================

module gather_fsm (
    input               rd_done,
    input               wr_done,
    input               comp_start,

    // 只需要对读地址进行仲裁
    input [15:0]        arbase_incdces,
    input [15:0]        arsize_incdces,
    input [15:0]        arbase_data_gen,
    input [15:0]        arsize_data_gen,
    input [15:0]        awbase_gen,
    input [15:0]        awsize_gen,
    input               addr_gen_valid,
    // 读最后一行数据时拉高
    input               rd_last_line,

    output reg [15:0]   arbase,
    output reg [15:0]   arsize,
    output reg [15:0]   awbase,
    output reg [15:0]   awsize,

    output reg          rd_start,
    output reg          wr_start,
    output reg          comp_done,
    output reg          rd_indices,
    output reg          trans_data,
    output reg          gen_status,

    input               clk,
    input               rst_n
);

localparam  IDLE = 3'd0         ;
localparam  RD_INDICES = 3'd1   ;
localparam  R_INDICES_DONE = 3'd2;
localparam  GEN_ADDR = 3'd3     ;
localparam  WR_PIPLINE = 3'd4   ;
localparam  COMP_DONE = 3'd5    ;

reg         rd_done_reg;
reg         wr_done_reg;
reg [15:0]  arbase_data_gen_reg;
reg [15:0]  arsize_data_gen_reg;
reg [15:0]  awbase_gen_reg;
reg [15:0]  awsize_gen_reg;

reg [2:0]   state;
reg [2:0]   next_state;
reg [2:0]   pre_state;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        rd_done_reg <= 1'b0;
    else if(rd_done)
        rd_done_reg <= 1'b1;
    else if(state == GEN_ADDR)
        rd_done_reg <= 1'b0;
    else
        rd_done_reg <= rd_done_reg;
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        wr_done_reg <= 1'b0;
    else if(wr_done)
        wr_done_reg <= 1'b1;
    else if(state == GEN_ADDR)
        wr_done_reg <= 1'b0;
    else
        wr_done_reg <= wr_done_reg;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        arbase_data_gen_reg <= 16'd0;
        arsize_data_gen_reg <= 16'd0;
        awbase_gen_reg <= 16'd0;
        awsize_gen_reg <= 16'd0;
    end
    else begin
        if(state == GEN_ADDR)
        begin
            arbase_data_gen_reg <= arbase_data_gen;
            arsize_data_gen_reg <= arsize_data_gen;
            awbase_gen_reg <= awbase_gen;
            awsize_gen_reg <= awsize_gen;
        end
        else begin
            arbase_data_gen_reg <= arbase_data_gen_reg;
            arsize_data_gen_reg <= arsize_data_gen_reg;
            awbase_gen_reg <= awbase_gen_reg;
            awsize_gen_reg <= awsize_gen_reg;
        end
    end
end


// State transition logic
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        pre_state <= IDLE;
    end else begin
        state <= next_state;
        if(next_state != state)
            pre_state <= state;
    end
end

// Next state logic
always @(*) begin
    next_state = state; // Default keep current state
    case (state)
        IDLE: begin
            if (comp_start) begin
                next_state = RD_INDICES;
            end
        end
        RD_INDICES: begin
            if (rd_done_reg) begin
                next_state = GEN_ADDR;
            end
        end
        R_INDICES_DONE: begin
            next_state = GEN_ADDR;
        end
        GEN_ADDR: begin
            if (addr_gen_valid) begin
                next_state = WR_PIPLINE; 
            end
        end
        WR_PIPLINE: begin
            if (rd_done_reg && wr_done_reg) begin
                next_state = rd_last_line ? COMP_DONE : GEN_ADDR; 
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

// Output logic
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        arbase <= 16'd0;
        arsize <= 16'd0;
        awbase <= 16'd0;
        awsize <= 16'd0;
        rd_start <= 1'b0;
        wr_start <= 1'b0;
        comp_done <= 1'b0;
        rd_indices <= 1'b0;
        trans_data <= 1'b0;
        gen_status <= 1'd0;
    end
    else begin
        case (state)
            IDLE: begin
                // All control signals low
                arbase <= 16'd0;
                arsize <= 16'd0;
                awbase <= 16'd0;
                awsize <= 16'd0;
                rd_start <= 1'b0;
                wr_start <= 1'b0;
                comp_done <= 1'b0;
                rd_indices <= 1'b0;
                trans_data <= 1'b0;
                gen_status <= 1'd0;
            end
            RD_INDICES: begin
                // Set arbase and arsize pointing to indices
                arbase <= arbase_incdces;
                arsize <= arsize_incdces;
                awbase <= 16'd0;
                awsize <= 16'd0;
                // Typically assert start signal here if triggering DMA
                rd_start <= 1'b1; 
                wr_start <= 1'b0;
                comp_done <= 1'b0;
                rd_indices <= 1'b1;
                trans_data <= 1'b0;
                gen_status <= 1'b0;
            end
            R_INDICES_DONE: begin
                arbase <= arbase;
                arsize <= arsize;
                awbase <= 16'd0;
                awbase <= 16'd0;
                rd_start <= 1'b0; 
                wr_start <= 1'b0;
                comp_done <= 1'b0;
                rd_indices <= 1'b0;
                trans_data <= 1'b0;
                gen_status <= 1'b0;
            end
            GEN_ADDR: begin
                // Placeholder for next stage
                arbase <= arbase;
                arsize <= arsize;
                awbase <= awbase;
                awsize <= awsize;
                rd_start <= 1'b0;
                wr_start <= 1'b0;
                comp_done <= 1'b0;
                rd_indices <= 1'b0;
                trans_data <= 1'b0;
                gen_status <= 1'b1;
            end
            WR_PIPLINE: begin 
                arbase <= arbase_data_gen_reg;
                arsize <= arsize_data_gen_reg;
                awbase <= awbase_gen_reg;
                awsize <= awsize_gen_reg;
                rd_start <= 1'b1;
                wr_start <= 1'b1;
                comp_done <= 1'b0;
                rd_indices <= 1'b0;
                trans_data <= 1'b1;
                gen_status <= 1'b0;
            end
            COMP_DONE: begin
                arbase <= 16'b0;
                arsize <= 16'b0;
                awbase <= 16'b0;
                awsize <= 16'b0;
                rd_start <= 1'b0;
                wr_start <= 1'b0;
                comp_done <= 1'b1;
                rd_indices <= 1'b0;
                trans_data <= 1'b0;
                gen_status <= 1'b0;
            end
            default: begin
                arbase <= 16'b0;
                arsize <= 16'b0;
                awbase <= 16'b0;
                awsize <= 16'b0;    
                rd_start <= 1'b0;
                wr_start <= 1'b0;
                comp_done <= 1'b0;
                rd_indices <= 1'b0;
                gen_status <= 1'b0;
            end
        endcase
    end
end
    
endmodule
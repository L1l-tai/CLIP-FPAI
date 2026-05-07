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

module hadamard_fsm (
    input               rd_done,
    input               wr_done,
    input               hd_comp_start, // 修正：使用正确的端口名

    // 只需要对读地址进行仲裁
    input [31:0]        arbase_hd_gen,
    input [15:0]        arsize_hd_gen,
    input [31:0]        awbase_hd_gen,
    input [15:0]        awsize_hd_gen,
    input               hd_addr_gen_valid,
    // 读最后一行数据时拉高
    input               hd_first_line,
    input               hd_last_line,
    input               fwht_done,

    output reg [31:0]   arbase,
    output reg [15:0]   arsize,
    output reg [31:0]   awbase,
    output reg [15:0]   awsize,

    output reg          rd_start,
    output reg          wr_start,
    output reg          comp_done,
    
    //MSB: WR; LSB:RD
    output reg [1:0]    trans_status,
    output reg          gen_status,
    output reg          fwht_status,

    input               clk,
    input               rst_n
);

localparam  IDLE = 3'd0         ;
localparam  GEN_ADDR = 3'd1     ;
localparam  RD_ONLY = 3'd2      ;
localparam  FWHT = 3'd3         ;
localparam  WR_PIPLINE =3'd4    ;
localparam  WR_ONLY = 3'd5      ;
localparam  COMP_DONE = 3'd6    ;

reg         rd_done_reg;
reg         wr_done_reg;
reg [31:0]  arbase_hd_gen_reg;
reg [15:0]  arsize_hd_gen_reg;
reg [31:0]  awbase_hd_gen_reg;
reg [15:0]  awsize_hd_gen_reg;

reg [2:0]   state;
reg [2:0]   next_state;
//reg [2:0]   pre_state;

reg         wr_start_pulse_gen;
reg         rd_start_pulse_gen;

wire        wr_ddr;
wire        rd_ddr;

assign wr_ddr = (state == WR_PIPLINE) | (state == WR_ONLY);
assign rd_ddr = (state == WR_PIPLINE) | (state == RD_ONLY); 

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
        arbase_hd_gen_reg <= #0.1 32'd0;
        arsize_hd_gen_reg <= #0.1 16'd0;
        awbase_hd_gen_reg <= #0.1 32'd0;
        awsize_hd_gen_reg <= #0.1 16'd0;
    end
    else begin
        if(state == GEN_ADDR)
        begin
            arbase_hd_gen_reg <= #0.1 arbase_hd_gen;
            arsize_hd_gen_reg <= #0.1 arsize_hd_gen;
            awbase_hd_gen_reg <= #0.1 awbase_hd_gen;
            awsize_hd_gen_reg <= #0.1 awsize_hd_gen;
        end
        else begin
            arbase_hd_gen_reg <= #0.1 arbase_hd_gen_reg;
            arsize_hd_gen_reg <= #0.1 arsize_hd_gen_reg;
            awbase_hd_gen_reg <= #0.1 awbase_hd_gen_reg;
            awsize_hd_gen_reg <= #0.1 awsize_hd_gen_reg;
        end
    end
end

// State transition logic
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= #0.1 IDLE;
    end else begin
        state <= #0.1 next_state;
    end
end

// Next state logic
always @(*) begin
    next_state = state; // Default keep current state
    case (state)
        IDLE: begin
            // 修正：使用 hd_comp_start 替代未定义的 comp_start
            if (hd_comp_start) begin
                next_state = GEN_ADDR;
            end
        end
        GEN_ADDR: begin
            if (hd_addr_gen_valid) begin
                next_state = hd_first_line ? RD_ONLY : hd_last_line ? WR_ONLY : WR_PIPLINE;
            end
        end
        RD_ONLY: begin
            if (rd_done_reg) begin
                next_state = FWHT; 
            end
        end
        FWHT: begin
            if (fwht_done) begin
                next_state = GEN_ADDR; 
            end
        end
        WR_PIPLINE: begin
            if (rd_done_reg && wr_done_reg) begin
                next_state = FWHT; 
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

// Output logic
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        arbase <= #0.1 32'd0;
        arsize <= #0.1 16'd0;
        awbase <= #0.1 32'd0;
        awsize <= #0.1 16'd0;
        comp_done <= #0.1 1'b0;
        trans_status <= #0.1 2'b00;
        gen_status <= #0.1 1'd0;
        fwht_status <= #0.1 1'b0;
    end
    else begin
        case (state)
            IDLE: begin
                // All control signals low
                arbase <= #0.1 32'd0;
                arsize <= #0.1 16'd0;
                awbase <= #0.1 32'd0;
                awsize <= #0.1 16'd0;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b00;
                gen_status <= #0.1 1'd0;
                fwht_status <= #0.1 1'b0;
            end
            GEN_ADDR: begin
                // Set arbase and arsize pointing to indices
                arbase <= #0.1 arbase;
                arsize <= #0.1 arsize;
                awbase <= #0.1 awbase;
                awsize <= #0.1 awsize;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b00;
                gen_status <= #0.1 1'b1;
                fwht_status <= #0.1 1'b0;
            end
            RD_ONLY: begin
                arbase <= #0.1 arbase_hd_gen_reg;
                arsize <= #0.1 arsize_hd_gen_reg;
                awbase <= #0.1 32'd0;
                awsize <= #0.1 16'd0;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b01;
                gen_status <= #0.1 1'b0;
                fwht_status <= #0.1 1'b0;
            end
            FWHT: begin
                arbase <= #0.1 arbase;
                arsize <= #0.1 arsize;
                awbase <= #0.1 awbase;
                awsize <= #0.1 awsize;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b00;
                gen_status <= #0.1 1'b0;
                fwht_status <= #0.1 1'b1;
            end
            WR_PIPLINE: begin 
                arbase <= #0.1 arbase_hd_gen_reg;
                arsize <= #0.1 arsize_hd_gen_reg;
                awbase <= #0.1 awbase_hd_gen_reg;
                awsize <= #0.1 awsize_hd_gen_reg;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b11;
                gen_status <= #0.1 1'b0;
                fwht_status <= #0.1 1'b0;
            end
            WR_ONLY: begin
                arbase <= #0.1 32'b0;
                arsize <= #0.1 16'b0;
                awbase <= #0.1 awbase_hd_gen_reg;
                awsize <= #0.1 awsize_hd_gen_reg;
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b10;
                gen_status <= #0.1 1'b0;
                fwht_status <= #0.1 1'b0;
            end
            COMP_DONE: begin
                arbase <= #0.1 32'b0;
                arsize <= #0.1 16'b0;
                awbase <= #0.1 32'b0;
                awsize <= #0.1 16'b0;
                comp_done <= #0.1 1'b1;
                trans_status <= #0.1 2'b00;
                gen_status <= #0.1 1'b0;
                fwht_status <= #0.1 1'b0;
            end
            default: begin
                arbase <= #0.1 32'b0;
                arsize <= #0.1 16'b0;
                awbase <= #0.1 32'b0;
                awsize <= #0.1 16'b0;    
                comp_done <= #0.1 1'b0;
                trans_status <= #0.1 2'b00; 
                gen_status <= #0.1 1'b0;
                fwht_status <= #0.1 1'b0;
            end
        endcase
    end
end
    
endmodule

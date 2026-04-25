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

module hadamard_addr_gen(
    input        [1:0]      trans_status  ,
    input                   gen_status    ,
    input        [31:0]     hd_data_width ,

    input        [31 : 0]   arbase_hd     ,
    //需要读写的总数据包数(512bit)
    input        [31 : 0]   wrsize_hd     ,
    input        [31 : 0]   awbase_hd     ,
    
    // 新增：总迭代次数/行数，用于判断 last_line
    //input        [15 : 0]   fwht_num      ,

    output  reg             hd_addr_gen_valid , 
    output  reg  [31 : 0]   arbase_hd_gen,
    output  reg  [15 : 0]   arsize_hd_gen,
    output  reg  [31 : 0]   awbase_hd_gen,
    output  reg  [15 : 0]   awsize_hd_gen,
    output  reg             hd_first_line,
    output  reg             hd_last_line,
    
    input                   comp_done     ,

    input                   clk           ,
    input                   rst_n
);

localparam FWHT_WIDTH = 2; // 64 * 16 / 512 = 2, FP16每次迭代2个512bit块
localparam FWHT_SHIFT = 7; // 每次迭代地址偏移128字节 (2^7)

reg     [15 : 0]            hd_rd_cnt;
reg     [15 : 0]            hd_wr_cnt;
reg     [1 : 0]             trans_status_reg;

reg     [31 : 0]            arbase_hd_reg;
reg     [31 : 0]            awbase_hd_reg;

wire       [31 : 0]         arbase_hd_gen_c;
wire       [15 : 0]         arsize_hd_gen_c;
wire       [31 : 0]         awbase_hd_gen_c;
wire       [15 : 0]         awsize_hd_gen_c;
wire       [31 : 0]         arbase_offset_c;
wire       [31 : 0]         awbase_offset_c;

wire       [15 : 0]         wfht_num;
wire                        rd_pos;
wire                        wr_pos;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        arbase_hd_reg <= #0.1 32'b0;
        awbase_hd_reg <= #0.1 32'b0;
    end
    else begin
        arbase_hd_reg <= #0.1 arbase_hd;
        awbase_hd_reg <= #0.1 awbase_hd;
    end
end


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
        hd_rd_cnt <= #0.1 16'd0;
    end
    else begin
        if(rd_pos) begin
            //每完成一次地址生成，即进入下一个状态时，cnt加1
            hd_rd_cnt <= #0.1 hd_rd_cnt + 16'd1;
        end
        else if(comp_done) begin
            hd_rd_cnt <= #0.1 16'd0;
        end
        else begin
            hd_rd_cnt <= #0.1 hd_rd_cnt;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hd_wr_cnt <= #0.1 16'd0;
    end
    else begin
        if(wr_pos) begin
            //每完成一次地址生成，即进入下一个状态时，cnt加1
            hd_wr_cnt <= #0.1 hd_wr_cnt + 16'd1;
        end
        else if(comp_done) begin
            hd_wr_cnt <= #0.1 16'd0;
        end
        else begin
            hd_wr_cnt <= #0.1 hd_wr_cnt;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        hd_addr_gen_valid <= #0.1 1'b0;
        arbase_hd_gen <= #0.1 32'b0;
        arsize_hd_gen <= #0.1 16'b0;
        awbase_hd_gen <= #0.1 32'b0;
        awsize_hd_gen <= #0.1 16'b0;
    end
    else begin
        if(gen_status) begin
            hd_addr_gen_valid <= #0.1 1'b1;
            arbase_hd_gen <= #0.1 arbase_hd_gen_c;
            arsize_hd_gen <= #0.1 arsize_hd_gen_c;
            awbase_hd_gen <= #0.1 awbase_hd_gen_c;
            awsize_hd_gen <= #0.1 awsize_hd_gen_c;
        end
        else begin
            hd_addr_gen_valid <= #0.1 1'b0;
            arbase_hd_gen <= arbase_hd_gen;
            arsize_hd_gen <= arsize_hd_gen;
            awbase_hd_gen <= awbase_hd_gen;
            awsize_hd_gen <= awsize_hd_gen;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hd_last_line <= #0.1 1'b0;
        hd_first_line <= #0.1 1'b0;
    end
    else begin
        if(gen_status) begin
            hd_last_line <= #0.1 (hd_wr_cnt == fwht_num - 1);
            hd_first_line <= #0.1 (hd_rd_cnt == 16'd0);
        end
        else if(comp_done) begin
            hd_last_line <= #0.1 1'b0;
            hd_first_line <= #0.1 1'b0;
        end
        else begin
            hd_last_line <= #0.1 hd_last_line;
            hd_first_line <= #0.1 hd_first_line;
        end
    end
end

assign wfht_num = wrsize_hd / FWHT_WIDTH;

assign rd_pos = ~trans_status_reg[0] & trans_status[0];
assign wr_pos = ~trans_status_reg[1] & trans_status[1];

assign arbase_offset_c = hd_rd_cnt << FWHT_SHIFT ;  // 64 * (32 / 8) = 256 BYTE
// 修正：直接使用组合逻辑偏移量，避免额外寄存器延迟导致地址错位
assign arbase_hd_gen_c = arbase_hd_reg + arbase_offset_c;
assign arsize_hd_gen_c = FWHT_WIDTH;

assign awbase_offset_c = hd_wr_cnt << FWHT_SHIFT;
// 修正：直接使用组合逻辑偏移量
assign awbase_hd_gen_c = awbase_hd_reg + awbase_offset_c;
assign awsize_hd_gen_c = FWHT_WIDTH;

endmodule

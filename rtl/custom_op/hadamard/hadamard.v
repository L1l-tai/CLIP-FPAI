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

module hadamard (
    input                   fwht_status   ,
    input        [1 : 0]    trans_status  ,
    input                   cal_percision ,

    input        [511 : 0]  din           ,
    input                   din_valid     ,
    output                  din_ready     ,

    output       [511 : 0]  dout          ,
    output                  dout_valid    ,
    input                   dout_ready    ,
    
    //input      [ 15: 0]     arsize        ,
    input                   comp_done     ,

    input                   clk           ,
    input                   rst_n
);

reg     [15:0]              fwht_regs   [63:0];
reg     [15:0]              fwht_out_regs [63:0]; 
reg     [1 : 0]             trans_status_reg;
reg     [1 : 0]             rd_cnt;
reg     [1 : 0]             wr_cnt;

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
            //算子处理完成或读取完毕后，清零计数器
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
            if(cal_percision) begin
                fwht_regs[i] <= #0.1 {8'b0, din[i * 8 + 7 : i * 8]};
            end
            else begin
                fwht_regs[i] <= #0.1 cal_percision ? din[i * 16 + 15 : i * 16];
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
            fwht_regs[j] <= #0.1 16'd0;
        end
        else if(din_valid & din_ready) begin
            if(cal_percision & rd_cnt==2'd0) begin
                fwht_regs[j] <= #0.1 {8'b0, din[(j + 32) * 8 + 7 : (j + 32) * 8]};
            end
            else if(~cal_percision & rd_cnt == 2'd1) begin
                fwht_regs[j] <= #0.1 cal_percision ? din[j*16+15:j*16];
            end
            else begin
                fwht_regs[j] <= #0.1 fwht_regs[j];
            end
        end
        else begin
            fwht_regs[j] <= #0.1 fwht_regs[j];
        end
    end
end
endgenerate


assign din_ready = trans_status[0];


assign trans_data_pos = ~trans_data_reg & trans_data;

assign indice_now = current_indices[current_indices_cnt*32+ : 32];

assign arbase_offset_c = indice_now_reg * (data_width_reg << 6);
assign arbase_data_gen_c = arbase_data_reg + arbase_offset;
assign arsize_data_gen_c = data_width_reg;

assign awbase_offset_c = output_addr_cnt * (data_width_reg << 6);
assign awbase_gen_c = awbase_dout_reg + awbase_offset;
assign awsize_gen_c = data_width_reg;

assign dout_rs = rd_indices ? 512'd0 : din;
assign din_ready = rd_indices ? ~indices_fifo_almost_full : dout_ready_rs;
assign dout_valid_rs  = rd_indices ? 1'b0 : din_valid && din_ready;

assign indices_fifo_winc = rd_indices & din_valid & ~indices_fifo_almost_full;
assign indices_fifo_wdata = rd_indices ? din : 512'b0;
assign current_indices = (indices_fifo_empty | rd_indices) ? 512'b0 : indices_fifo_dout;

sync_fifo_reg
#(
    .ALMOST_FULL_TH (20),
    .DSIZE          (512),
    .ASIZE          (5)
)
indices_fifo_0
(
    .clk            (clk                      ),//input 
    .rst_n          (rst_n                    ),//input 
    .winc           (indices_fifo_winc        ),//input 
    .wdata          (indices_fifo_wdata       ),//input 
    .wfull          (                         ),//output
    .wfull_almost   (indices_fifo_almost_full ),//output
    .rempty         (indices_fifo_empty       ),//output
    .rinc           (indices_fifo_rinc        ),//input 
    .rdata          (indices_fifo_dout        )	//output
);

// 实例化 AVR 寄存器切片模块 (avr_rs)
// 作用：隔离组合逻辑路径，改善时序，并提供背压处理能力
avr_rs #(.DW(512)) U_avr_rs(
    .m_data      ( dout_rs         ),//I - 主接口数据输入
    .m_valid     ( dout_valid_rs   ),//I - 主接口有效信号
    .m_ready     ( dout_ready_rs   ),//O - 主接口就绪信号

    .s_data      ( dout            ),//O - 从接口数据输出
    .s_valid     ( dout_valid      ),//O - 从接口有效信号
    .s_ready     ( dout_ready      ),//I - 从接口就绪信号

    .clk         ( clk            ),
    .rst_n       ( rst_n          )
);


endmodule
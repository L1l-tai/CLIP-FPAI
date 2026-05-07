//================================================================================
// File Name     : gather_top.v
// Project       : 
// Create Date   : 2026.04.10
// Description   :
// 
//--------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who               Description
//================================================================================

module gather (
    input                   rd_indices    ,     // dma读索引信号
    input                   trans_data    ,
    input                   gen_status    ,
    input        [31:0]     indices_width ,
    input        [31:0]     data_width    ,

    input        [511 : 0]  din           ,
    input                   din_valid     ,
    output                  din_ready     ,

    input        [31 : 0]   arbase_data   ,
    //input        [15 : 0]   arsize_data   ,
    input        [31 : 0]   awbase_dout   ,
    //input        [15 : 0]   awsize_dout   ,

    output  reg             addr_gen_valid ,
    output  reg  [31 : 0]   arbase_data_gen,
    output  reg  [15 : 0]   arsize_data_gen,
    output  reg  [31 : 0]   awbase_gen,
    output  reg  [15 : 0]   awsize_gen,
    output  reg             rd_last_line,

    output       [511 : 0]  dout          ,
    output                  dout_valid    ,
    input                   dout_ready    ,
    
    //input      [ 15: 0]     arsize        ,
    input                   comp_done     ,

    input                   clk           ,
    input                   rst_n
);

wire                        indices_fifo_winc;
wire    [511 : 0]           indices_fifo_wdata;
wire                        indices_fifo_almost_full;
wire                        indices_fifo_empty; 
reg                         indices_fifo_rinc;
wire    [511 : 0]           indices_fifo_dout;
//reg     [511 : 0]           indices_fifo_dout_reg;

wire    [511 : 0]           current_indices;
reg     [3 : 0]             current_indices_cnt;
reg     [7 : 0]             output_addr_cnt;
reg                         rinc_pulse_gen; //生成单周期脉冲的状态寄存器
reg                         trans_data_reg;
wire                        trans_data_pos;
wire    [31 : 0]            indice_now;
reg     [31 : 0]            indice_now_reg;
reg     [31 : 0]            data_width_reg;
reg     [31 : 0]            indices_width_reg;
reg     [31 : 0]            arbase_data_reg;
reg     [31 : 0]            awbase_dout_reg;

wire    [511 : 0]           dout_rs    ;
wire                        dout_valid_rs  ;
wire                        dout_ready_rs  ;

wire       [31 : 0]         arbase_data_gen_c;
wire       [15 : 0]         arsize_data_gen_c;
wire       [31 : 0]         awbase_gen_c;
wire       [15 : 0]         awsize_gen_c;
wire       [31 : 0]         arbase_offset_c;
wire       [31 : 0]         awbase_offset_c;

reg        [31 : 0]         arbase_offset;
reg        [31 : 0]         awbase_offset;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        indice_now_reg <= #0.1 32'b0;
        data_width_reg <= #0.1 32'b0;
        indices_width_reg <= #0.1 32'b0;
        arbase_data_reg <= #0.1 32'b0;
        awbase_dout_reg <= #0.1 32'b0;
    end
    else begin
        indice_now_reg <= #0.1 indice_now;
        data_width_reg <= #0.1 data_width;
        indices_width_reg <= #0.1 indices_width;
        arbase_data_reg <= #0.1 arbase_data;
        awbase_dout_reg <= #0.1 awbase_dout;
    end
end

always@(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        arbase_offset <= #0.1 32'b0;
        awbase_offset <= #0.1 32'b0;
    end
    else begin
        arbase_offset <= #0.1 arbase_offset_c;
        awbase_offset <= #0.1 awbase_offset_c;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        trans_data_reg <= #0.1 1'b0;
    end
    else begin
        trans_data_reg <= #0.1 trans_data;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        indices_fifo_rinc <= #0.1 1'b0;
        rinc_pulse_gen    <= #0.1 1'b0;
        //初始值为1，初始cnt为0时不拉高rinc
    end
    else begin 
        // 当计数器为0时，尝试生成一个周期的读取脉冲
        if (current_indices_cnt == 0 & trans_data_reg) begin
            if (!rinc_pulse_gen) begin
                indices_fifo_rinc <= #0.1 1'b1;
                rinc_pulse_gen    <= #0.1 1'b1;
            end
            else begin
                indices_fifo_rinc <= #0.1 1'b0;
            end
        end
        else begin
            indices_fifo_rinc <= #0.1 1'b0;
            rinc_pulse_gen    <= #0.1 1'b0; // 复位脉冲生成器，允许下一次 cnt==0 时触发
        end
    end    
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        current_indices_cnt <= #0.1 4'd0;
        output_addr_cnt <= #0.1 8'd0;
    end
    else begin
        if(trans_data_pos) begin
            //每完成一次地址生成，即进入下一个状态时，cnt加1
            current_indices_cnt <= #0.1 current_indices_cnt + 4'd1;
            output_addr_cnt <= #0.1 output_addr_cnt + 8'd1;
        end
        else if(comp_done) begin
            current_indices_cnt <= #0.1 4'd0;
            output_addr_cnt <= #0.1 8'd0;
        end
        else begin
            current_indices_cnt <= #0.1 current_indices_cnt;
            output_addr_cnt <= #0.1 output_addr_cnt;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        addr_gen_valid <= #0.1 1'b0;
        arbase_data_gen <= #0.1 32'b0;
        arsize_data_gen <= #0.1 16'b0;
        awbase_gen <= #0.1 32'b0;
        awsize_gen <= #0.1 16'b0;
    end
    else begin
        if(gen_status) begin
            addr_gen_valid <= #0.1 1'b1;
            arbase_data_gen <= #0.1 arbase_data_gen_c;
            arsize_data_gen <= #0.1 arsize_data_gen_c;
            awbase_gen <= #0.1 awbase_gen_c;
            awsize_gen <= #0.1 awsize_gen_c;
        end
        else begin
            addr_gen_valid <= #0.1 1'b0;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_last_line <= #0.1 1'b0;
    end
    else begin
        if(gen_status) begin
            rd_last_line <= #0.1 output_addr_cnt == indices_width_reg - 1;
        end
        else if(comp_done) begin
            rd_last_line <= #0.1 1'b0;
        end
        else begin
            rd_last_line <= #0.1 rd_last_line;
        end
    end
end

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
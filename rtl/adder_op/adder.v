
//==============================================================================
// Orgnization   : Shanghai Fudan Microelectronics Co., Ltd. Confidential
// File Name     : adder.v
// Author        :
// Project       : 
// Create Date   : 2021.04.05
// Description   :
// - 32 bit adder
//------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who          Description
// 
//==============================================================================

module adder(

    input        [ 31 : 0]  a             ,
    input                   a_valid       ,
    output                  a_ready       ,

    output       [ 63 : 0]  sum           ,
    output                  sum_valid     ,
    input                   sum_ready     ,
    
    input      [ 15: 0]     arsize        ,
    output reg              comp_done     ,

    input                   clk           ,
    input                   rst_n
);

   reg   [ 8 : 0]  cnt           ;
   
   wire  [63 : 0]  sum_rs        ;
   wire            sum_valid_rs  ;
   wire            sum_ready_rs  ;

   assign sum_rs = 1 + a;

   assign a_ready      = sum_ready_rs;
   assign sum_valid_rs = a_valid && a_ready;

   // 计数器逻辑：
   // 复位时清零；
   // 当计算完成标志置位时清零；
   // 当AVR模块成功传输一次数据(valid & ready)时，计数器加1
   always @(posedge clk or negedge rst_n)begin
     if(rst_n==1'b0)
       cnt <= #0.1 'd0;
     else if(comp_done)
       cnt <= #0.1 'd0;
     else if(sum_valid_rs && sum_ready_rs)
       cnt <= #0.1 cnt + 1'b1;
   end
  
   // 计算完成标志逻辑：
   // 复位时清零；
   // 如果已经完成，保持清零状态（单次触发模式）；
   // 当计数器达到设定的长度(arsize)时，置位完成标志
   always @(posedge clk or negedge rst_n)begin
     if(rst_n==1'b0)
       comp_done <= #0.1 1'b0;
     else if(comp_done)
       comp_done <= #0.1 1'b0;
     else if(cnt==arsize)
       comp_done <= #0.1 1'b1;
   end

    // 实例化 AVR 寄存器切片模块 (avr_rs)
    // 作用：隔离组合逻辑路径，改善时序，并提供背压处理能力
    avr_rs #(.DW(64)) U_avr_rs(
        .m_data      ( sum_rs         ),//I - 主接口数据输入
        .m_valid     ( sum_valid_rs   ),//I - 主接口有效信号
        .m_ready     ( sum_ready_rs   ),//O - 主接口就绪信号

        .s_data      ( sum            ),//O - 从接口数据输出
        .s_valid     ( sum_valid      ),//O - 从接口有效信号
        .s_ready     ( sum_ready      ),//I - 从接口就绪信号

        .clk         ( clk            ),
        .rst_n       ( rst_n          )
    );



endmodule



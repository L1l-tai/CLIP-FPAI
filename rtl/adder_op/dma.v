
//==============================================================================
// Orgnization   : Shanghai Fudan Microelectronics Co., Ltd. Confidential
// File Name     : dma.v
// Author        :
// Project       : 
// Create Date   : 2021.04.01
// Description   :
// - Direct Memory Access
//------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who          Description
// 
//==============================================================================

module dma(

    input         [ 15: 0]     arbase        , // 读地址基地址
    input         [ 15: 0]     arsize        , // 读数据长度（字数）
                                            
    input         [ 15: 0]     awbase        , // 写地址基地址
    input         [ 15: 0]     awsize        , // 写数据长度（字数）

    output  reg   [ 31: 0]     araddr        , // 读地址总线
    output  reg                arvalid       , // 读地址有效信号
    input                      arready       , // 读地址就绪信号

    input         [ 63: 0]     comp_data     , // 计算结果数据输入
    input                      data_valid    , // 计算数据有效信号
    output                     data_ready    , // 数据接收就绪信号

    output  reg   [ 31: 0]     awaddr        , // 写地址总线
    output        [ 63: 0]     awdata        , // 写数据总线
    output                     awvalid       , // 写地址/数据有效信号
    input                      awready       , // 写地址/数据就绪信号

    input                      comp_start    , // DMA传输启动信号

    input                      clk           , // 时钟信号
    input                      rst_n         // 复位信号，低电平有效

);

   reg   [15 : 0]  dma_cnt0 ;   //读数据计数器
   reg   [15 : 0]  dma_cnt1 ;   //写数据计数器
   wire            aawready ;
   reg             aawvalid ;

   assign data_ready = awready;

   assign aawready   = awready && data_valid;

   assign awdata     = comp_data;
   assign awvalid    = aawvalid && data_valid;

   // 写地址有效信号控制逻辑：
   // 复位时清零；启动时置位；当最后一个数据写入完成（计数器为0且握手成功）时清零
   always@(posedge clk or negedge rst_n)begin
        if(rst_n==1'b0)
            aawvalid <= #0.1 1'b0;
        else if(comp_start)
            aawvalid <= #0.1 1'b1;
        else if(aawready && dma_cnt1==0)
            aawvalid <= #0.1 1'b0;
   end

   // 写数据计数器逻辑：
   // 复位时清零；启动时加载写长度；每次写握手成功时减1
   always@(posedge clk or negedge rst_n)begin
        if(rst_n==1'b0)
            dma_cnt1 <= #0.1 0;
        else if(comp_start)
            dma_cnt1 <= #0.1 awsize;
        else if(aawvalid & aawready)
            dma_cnt1 <= #0.1 dma_cnt1 - 1'b1;
   end

   // 写地址生成逻辑：
   // 复位时清零；启动时加载基地址；每次写握手成功时地址增加64（字节偏移）
   always@(posedge clk or negedge rst_n)begin
        if(rst_n==1'b0)
            awaddr <= #0.1 0;
        else if(comp_start)
            awaddr <= #0.1 awbase;
        else if(aawvalid & aawready)
            awaddr <= #0.1 awaddr + 64;
   end
   
   // 读数据计数器逻辑：
   // 复位时清零；启动时加载读长度；每次读握手成功时减1
   always@(posedge clk or negedge rst_n)begin
        if(rst_n==1'b0)
            dma_cnt0 <= #0.1 0;
        else if(comp_start)
            dma_cnt0 <= #0.1 arsize;
        else if(arvalid & arready)
            dma_cnt0 <= #0.1 dma_cnt0-1'b1;
   end

   // 读地址生成逻辑：
   // 复位时清零；启动时加载基地址；每次读握手成功时地址增加64（字节偏移）
   always@(posedge clk or negedge rst_n)begin
        if(rst_n==1'b0)
            araddr <= #0.1 0;
        else if(comp_start)
            araddr <= #0.1 arbase;
        else if(arvalid & arready)
            araddr <= #0.1 araddr + 64;
   end

   // 读地址有效信号控制逻辑：
   // 复位时清零；启动时置位；当最后一个数据读取完成（计数器为0且握手成功）时清零
   always@(posedge clk or negedge rst_n)begin
        if(rst_n==1'b0)
            arvalid <= #0.1 1'b0;
        else if(comp_start)
            arvalid <= #0.1 1'b1;
        else if(arready && dma_cnt0==0)
            arvalid <= #0.1 1'b0;
   end
   
endmodule


  
